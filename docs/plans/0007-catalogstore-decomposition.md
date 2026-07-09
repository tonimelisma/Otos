# Plan 0007 — Decompose `CatalogStore` into Owned Sub-Components

> Non-authoritative plan. Delete when done.
> Execution order: **last** — the largest structural refactor; depends on
> plan 0006 (`RootRuntimeState`) and benefits from plan 0003 (removing the 41
> diagnostics call sites in this file first). Not urgent; do it deliberately,
> phased, each phase independently shippable.

## 1. Problem (verified)

`CatalogStore.swift` is **2,912 lines**, `CatalogStorePersistence.swift`
another **1,418** — one actor with **118 functions** and one enormous
extension block (the file has only two `extension` markers, at lines 228 and
1671). It owns SQLite, root identity, availability, scan + device-enumeration
leases, filesystem-event debounce/reconciliation, enrichment claim leases,
change-notification fan-out, thumbnail-store maintenance, and removable/camera
lifecycle. "Where does X happen" is buried; the file is the one nobody wants
to touch.

## 2. Hard constraint (must not be violated)

`ARC-003` (CatalogStore single-actor ownership) requires **one actor** as the single owner
of GRDB, root runtime state, scan/enumeration leases, removable-source state,
scan cadence, and all catalog queries. Therefore this plan does **not** split
`CatalogStore` into multiple actors — doing so would introduce new
cross-actor awaits (losing the "serialized for free" guarantee) and violate a
documented architecture rule.

**The decomposition is by *ownership within the one actor*, not by isolation
domain.** Extract cohesive **owned helper types** — pure decision logic and
state bookkeeping the actor holds and calls synchronously inside its own
isolation. This is the repo's existing pattern: `CatalogWindowPolicy` and
`SidebarSelectionPolicy` are pure helpers beside effectful actors. We apply it
to the Store's own internals. Effectful orchestration (spawning tasks,
awaiting the DB, firing notifications) stays in `CatalogStore`; the helpers
are non-`Sendable` types confined to the actor and unit-testable in isolation.

## 3. Target component map

| Owned component | State it holds | Pure vs effectful | Extracted from |
| --- | --- | --- | --- |
| `RootRegistry` (from plan 0006) | `rootStatesByPath`, `pathsByRowID`; query-id derivation, availability/activity transitions, device-identity lookup, priority ordering | pure state + logic | ~90 refs across the root/query/attach methods |
| `ScanLeaseController` | `activeScan`, `activeDeviceScans`, `nextActiveScanLeaseGeneration`, `pendingScanPaths`, `rescanAfterCurrentScan` | pure bookkeeping (decides "may this write proceed / what scans next"); the actor owns `currentScanTask` and spawns work | scan lease + queue methods (`enqueueScans`, `startNextScanIfNeeded`, `beginDeviceCatalogEnumeration`, lease re-checks) |
| `FilesystemReconciler` | `filesystemWatchingArmed`, `rescanAfterCurrentScan` (shared read), event batches, debounce config | pure classifier: `(event batch) -> ReconcileAction` (`upsertPath` / `deletePath` / `rescanRoot` / `defer`) | `filesystemEventBatches`, debounce/classification (`classify…`, the 6-line "directory/symlink/dropped → enqueueScans" logic) |
| `EnrichmentLeaseGateway` | claim SQL + `enrichment_claimed_until` policy | effectful (SQL) but cohesive | the 8 enrichment-claim methods + persistence |
| `CatalogStorePersistence` | GRDB, migrations, row mapping | effectful (SQL) | already separate — keep |
| `CatalogStore` (facade actor) | `dbWriter`, `startupTask`, `currentScanTask`, `changeContinuations`, `filesystemDebounceTasks`; composes the above and owns all task/await orchestration + the public API | effectful orchestration | remains the only actor + public surface |

The public method surface (≈25 methods; verified external call sites in
`EnrichmentCoordinator`, `CatalogProjection*`, the two ViewModel extensions,
the monitors) **does not change** — this is internal reorganization behind the
same actor.

## 4. Why these seams (evidence, not vibes)

- The six root dicts already form one record (plan 0006) → `RootRegistry` is
  the natural first extraction and is 90 of the file's references.
- Scan-lease code is identifiable by the "re-check I still own this scan after
  every await" pattern (onboarding §4 `ActiveScan`), keyed by
  `activeScan`/`activeDeviceScans`/lease generation — a self-contained state
  machine currently interleaved with DB writes.
- Filesystem reconciliation already has a documented pure-decision shape
  ("single regular-file create/modify → upsert one row; ambiguous → rescan
  that root") — it just isn't a type. Extracting the classifier makes the
  `CatalogStoreFilesystemEventTests` (344 lines) target a pure function
  instead of the whole actor.
- Enrichment claims are already a distinct concern with their own persistence
  and the `enrichment_claimed_until` lease; grouping them isolates the
  contended-claim logic.

## 5. Phasing (each phase is its own PR, independently shippable)

### Phase 1 status (2026-07-09)

**Shipped.** `RootRegistry` owns the two maps + mutators + query-id/priority/
overlap/watched-path helpers. `CatalogStore` keeps `.scanning` overlay,
orchestration, and the public API.

### Phase 2 status (2026-07-09)

**Shipped.** `FilesystemReconciler` is the pure batch classifier
(`FilesystemReconcileDecision`); Store keeps debounce tasks and effectful
execution. Focused unit tests cover drop/defer/rescan/targeted; existing
`CatalogStoreFilesystemEventTests` remain the integration gate.

### Phase 3 status (2026-07-09)

**Shipped.** `ScanLeaseController` owns filesystem/device lease bookkeeping,
the pending scan queue, and rescan-after-current-scan deferrals. `CatalogStore`
keeps `currentScanTask`, spawn/await orchestration, and the public
`ActiveScan` type. Focused unit tests cover enqueue dedupe, front priority,
ownership checks, cancel, deferred rescan, and generation increment;
`CatalogStoreLifecycleRaceTests` remain the integration gate.

1. **`RootRegistry`** — mechanically follows plan 0006: promote the two maps +
   mutators + query-id/priority helpers into a `RootRegistry` value the actor
   owns (`private var roots = RootRegistry()`), calling it synchronously.
   ~90 sites become `roots.foo(...)`. No behavior change.
2. **`FilesystemReconciler`** — extract the event-batch classifier as a pure
   function returning `ReconcileAction`; the actor keeps the debounce tasks
   and executes the action. Re-point `CatalogStoreFilesystemEventTests` at the
   pure classifier (delete the parts that only existed to reach it through the
   actor).
3. **`ScanLeaseController`** — extract lease/queue bookkeeping; the actor keeps
   `currentScanTask` and the spawn/await. The "stale scan rejected after
   remove" behavior (`CatalogStoreLifecycleRaceTests`) must stay green — this
   is the riskiest phase; do it with the race tests as the gate.
4. **`EnrichmentLeaseGateway`** — group claim/refresh/release + their SQL.
5. **File split**: with size lints now warnings (plan 0001), the extracted
   types live in their own files (`RootRegistry.swift`,
   `FilesystemReconciler.swift`, `ScanLeaseController.swift`,
   `EnrichmentLeaseGateway.swift`); `CatalogStore.swift` shrinks to the actor
   facade + orchestration (target well under 1,000 lines). This is a
   *cohesion-driven* split (one type per file), the opposite of the old
   line-count split.

Stop-and-reassess after phase 1: if `RootRegistry` alone materially improves
navigability and the owner is satisfied, phases 2–4 can be deferred
indefinitely. This plan is deliberately the lowest-priority item in the set.

## 6. Tests & evidence

- Behavior-preserving throughout: the existing store test suites
  (`CatalogStoreTests`, `…Enrichment`, `…FilesystemEvent`, `…LifecycleRace`,
  `…RemovableSource`, `…ThumbnailLifecycle`, `…QueryPlan`,
  `CatalogProjection*`) are the safety net and must stay green *without
  modification* except where a test is re-pointed at a newly-extracted pure
  helper (phases 2–3).
- Each extracted pure helper gets focused unit tests (fast, no actor, no DB
  for `RootRegistry`/`FilesystemReconciler`).
- After phase 3, run `script/smoke-run.sh` (add/remove library, attach/eject a
  card) and `script/logs.sh show` to confirm scan lease + notification
  behavior at runtime.
- No performance claim without measurement: if any DB path is touched, capture
  a `script/profile.sh "Time Profiler"`/`"File Activity"` before/after
  (Rule 2). This plan should be behavior- and performance-neutral by design.

## 7. Acceptance criteria

- `CatalogStore` remains a single actor; no new actor introduced; public API
  unchanged (external caller diff = zero).
- `CatalogStore.swift` under ~1,000 lines; each extracted component in its own
  file with a file guide and focused unit tests.
- All existing store/projection test suites pass; `verify.sh` green;
  runtime smoke + (if any DB path changed) a profiling trace attached.
- The `architecture.md` map and ADR update to describe the owner-within-actor
  decomposition.

## 8. Risks

- **Behavior drift in the scan-lease state machine** (phase 3) — the subtlest
  code in the file. Mitigation: `CatalogStoreLifecycleRaceTests` is the gate;
  do phase 3 alone, and if it fights back, ship phases 1–2 and stop.
- **Scope creep into "while I'm here" changes** — forbidden; this is a
  reorganization, not a redesign. Any behavior change belongs in its own
  requirement + plan.
- **Over-decomposition** — if a phase does not clearly improve navigability or
  testability, skip it. The single actor + `RootRegistry` (phase 1) already
  captures most of the value.
