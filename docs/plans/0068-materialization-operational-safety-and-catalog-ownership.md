# Plan 0068 — Materialization, operational safety, and catalog ownership (blank-slate repair)

Status: Proposed
Owner: agent
Branch: `feat/materialization-provider-unavailable` (extends `27798c3`/`e399bda`/`3acca7e`)

## 1. Summary

Three independently shipped fixes on `feat/materialization-provider-unavailable` each correct the right owner but leave a second-order gap that, left as a patch, becomes a permanent bandaid. This plan finishes all three from first principles — as a blank-slate design would have built them — with no new actor, protocol, or table until measurement demands it.

* **Materialization:** A dataless provider that refuses with `ETIMEDOUT` in 1s is a different fact from a provider that is slow. The current `FileMaterialization.pollMaterialization` upgrades the fast definite refusal into `providerMs≈120133 rerequestCount=112 outcome=timedOut` behind `MaterializationAdmissionPolicy.backgroundPerRootCap=1`, blocking the 32-item enrichment probe for two minutes. Per-file `k=2` short-circuit (`27798c3`) fixes the single file, not the 32-file storm. Blank-slate: one-URL `FileMaterialization` may probe bytes, one `MaterializationCoordinator` owns per-root live/provider state and suppresses further background admission on that root for a bounded cooldown — not a second coordinator, not a second queue.

* **Operational safety:** `script/smoke-run.sh is_import_active` grepped `log show --last 5m` (global-last-line-wins `start A start B finish A → idle`, 5m truncation, daemon drop → false-idle `kill` mid-`copyfile(3)`). `e399bda` moved to `sqlite3 -readonly SELECT FROM active_file_operation LIMIT 1`, but still false-idles on `SQLITE_BUSY` and ignores `active_reorganization_*` whose mid-move `kill` corrupts the no-overwrite recipe. Blank-slate: operational safety is a Store-owned durable-journal query, not a log scrape; the script is a thin `sqlite3 -readonly` reader that treats any failure as active.

* **Catalog ownership:** `Otos/Stores/CatalogStore.swift` at 3909 lines is a cohesion problem, not a lint problem. `3acca7e` moved four pure-SQL helpers to `Otos/Stores/CatalogQueryGateway.swift` (`nonisolated enum`, no new actor). The remainder still mixes two testable pure layers (SQL/mapping and physical-member reservation) inside the one actor that must remain atomic for `namespaceMutationEpoch`/`filesystemDirty`/`reorganizationLeases`/`ScanLeaseController`. Blank-slate: every scoped read goes through one `CatalogScopePredicate`; every pure SQL fragment lives in a `nonisolated` gateway; the actor keeps only epoch/lease/dirty orchestration plus `timedRead`/`timedWrite`.

## 2. Context — what was measured

* Real OneDrive provider in `ProviderNotServing` state: `open()+read(4096)` → `ETIMEDOUT` (errno 60 macOS / 110 Linux, or `"timed out"` text) in **1s**, `stat blocks=0` unchanged. Otos turned it into 120s wall time, 112 re-requests (`startDownloadingUbiquitousItem` once per `requestRetryInterval=1s`), `MaterializationCoordinator` `inFlight=1 rootBackgroundCap` blocked. Research: `docs/research/2026-08-03-post-increment-review-experiments.md §4d` and `docs/research/2026-08-07-plan-0065-stage3-verification.md` — provider readiness is a **recorded precondition**, never `pgrep`.

* `FileMaterialization` is the only place that may read bytes to test liveness (`FileHandle read(1)` bounded at kernel 1s). The scanner never reads bytes (`ADR 0008`). `MaterializationCoordinator` owns 16-transfer admission (`globalConcurrency=16`, `byteBudget=2GiB`, `largeVideoCap=2`, `backgroundPerRootCap=1`) and per-ID waiter coalescing; `EnrichmentCoordinator` owns the 32-claim window, 8-worker admission, handoff `globalOutstandingLimit=16 backgroundOutstandingPerRoot=2`, and the `[15,60,300,900] → ledger 900s` pacing (`Otos/Services/EnrichmentCoordinatorCompletion.swift:162`).

* `CatalogStore` is the only GRDB owner (`actor`, `docs/architecture.md` table). `RootRegistry.scopePredicate` → `CatalogScopePredicate` is the one scope value every scoped read must consume. `EnrichmentLeaseGateway` already exists for claim grouping.

## 3. Goals / non-goals

Goals: (a) a provider that says `no` in 1s never costs 120s, and never costs `32×2s`, (b) no script can `kill` an in-flight import or reorganization, even across `log show` windows, reboots, or `SQLITE_BUSY`, (c) `CatalogStore` has one gateway for pure SQL/mapping, one actor for atomic truth, and no second writer, with every future query addition landing in the gateway by construction.

Non-goals: retuning `timeout=120s`/`pollInterval=250ms`/`requestRetryInterval=1s` for healthy slow transfers (keep), changing the enrichment claim window (32) or handoff limits without measurement, adding eviction of the unreclaimable download bytes, adding a second enrichment queue, adding a second `CatalogStore` actor.

## 4. Blank-slate principles applied

* One owner per question. `SF_DATALESS` detection and one-URL trigger/poll stay in `FileMaterialization`. Per-root admission and coalescing stay in `MaterializationCoordinator`. Pacing and claim lifetime stay in `EnrichmentCoordinator`. Catalog truth stays in `CatalogStore`.

* Direct over speculative. No new layer/actor/protocol/cache/pool: the breaker is three fields on the existing coordinator; the smoke guard reuses `sqlite3+CATALOG_DB`; the catalog split is a `nonisolated enum` of pure functions.

* Simplicity before performance. Each track ships the simplest correct mechanics, proves the stall is gone on a real dead-provider capture, and only then considers tighter probe budgets.

* One implementation path. Preview and enrichment call the same `MaterializationRequesting.materialize(_:)`; `smoke-run.sh` and any future automation call the same Store journal predicate.

## 5. Track A — Provider-unavailable is a different fact (not a faster timeout)

### 5.1 Taxonomy (already landed, kept)

```
MaterializationOutcome:
  alreadyMaterialized | materialized          → isMaterialized = true
  requestFailed | timedOut | statusUnavailable | cancelled | insufficientLocalSpace → false
  providerUnavailable                              → false, NEW terminal, measured separately
     "provider definitively refused ETIMEDOUT twice consecutively; further polling would
      waste 120s holding rootBackgroundCap=1"  (distinct from timedOut for diagnostics)
```

`MaterializationResult { outcome, rerequestCount, elapsedMs }` unchanged. `isMaterialized` already returns false for the new case (`FileMaterialization.swift:364`).

### 5.2 One-URL probe — stays in FileMaterialization only

`FileMaterialization.probeProviderLiveness(of:) -> FileMaterializationProbeResult`:

```
enum FileMaterializationProbeResult { served | providerUnavailable | inconclusive }
```

* Production probe: `FileHandle(forReadingFrom: url).read(upToCount: 1)`. Returns `served` on any byte, `providerUnavailable` only for `NSError.code ∈ {60,110}` or `localizedDescription` containing `timed out`/`ETIMEDOUT` (lowercased), else `inconclusive`. Kernel caps `ETIMEDOUT` at ~1s, so a probe never blocks longer than the retry interval. No throw.

* This is the only deliberately byte-reading test in the app; every other consumer continues to gate on `FileMaterialization.status(of:)` (`SF_DATALESS` via `lstat`, ~7µs). `probe` is injected via `FileMaterializationProviders`:

```
struct FileMaterializationProviders {
  status: @Sendable (URL) -> FileMaterializationStatus
  request: @Sendable (URL) throws -> Void   // startDownloadingUbiquitousItem
  probe:   @Sendable (URL) -> FileMaterializationProbeResult
}
```

Existing tests updated to pass `probe: { _ in .inconclusive }` so no call site omits the dimension.

* Poll decision stays pure: `FileMaterialization.materializationPollDecision(now:nextRetry:status:) -> MaterializationPollDecision` (no I/O, no clock) so `materializationRerequestsUntilProviderClearsDataless` no longer flakes under `script/verify.sh` parallelism.

### 5.3 Per-file short-circuit — k=2 consecutive providerUnavailable

Inside `FileMaterialization.pollMaterialization(url:pollInterval:timeout:requestRetryInterval:providers:)`:

```
consecutiveProviderUnavailable = 0
loop Task.sleep(pollInterval) {
  case .retryNow:
    rerequestCount += 1
    requestDownload(retry: true)
    switch providers.probe(url) {
    case .providerUnavailable: consecutiveProviderUnavailable += 1
                               if >=2 { return (.providerUnavailable, rerequestCount) }
    case .served, .inconclusive: consecutiveProviderUnavailable = 0
    }
    nextRetry = now + requestRetryInterval
}
```

*Cost:* `~2×1s` wall time (`requestRetryInterval=1s` + two kernel 1s probes) vs 120s. Single transient `ETIMEDOUT` that heals on the next tick yields only one failure and does not short-circuit — verified by `singleTransientProviderUnavailableDoesNotShortCircuit → timedOut`.

### 5.4 Per-root circuit breaker — the missing piece (batch storm)

Per-file `k=2` alone still serializes: `EnrichmentCoordinatorWorkSelection.claimSkippingLedgerDeferrals(maxLedgerSkipPasses=4)` probes up to 32 candidates, each admission goes through `MaterializationCoordinator.schedulePass()` which admits at most one per root (`backgroundPerRootCap=1`). Sequence is `admit → 2s probe-fail → retryWorkIfNeeded → ledger`, then next file admitted. Total `≈ 32×2s = 64s` of blocked background progress.

**Blank-slate owner:** the breaker belongs on `MaterializationCoordinator` — it already owns `pendingByID`/`inFlightByID`/`backgroundByRoot`/`effectiveInteractiveCount` and the only `rejection(for:inFlight:)` policy check. No second actor, no second queue, no enrichment-side cache that can diverge.

**State added to the existing actor (three fields):**

```swift
// MaterializationCoordinator (actor) — new private state
private var providerUnavailableStreakByRoot: [LibraryRootPath: Int] = [:]
private var breakerOpenUntilByRoot: [LibraryRootPath: Date] = [:]
private let breakerThreshold = 2          // consecutive providerUnavailable on the root
private let breakerCooldown: Duration = .seconds(60)
```

**Policy extension:**

```swift
// MaterializationAdmissionPolicy.Rejection — new case
case providerBreakerOpen   // maps to log "reason=providerBreakerOpen rejected=N"
```

`MaterializationAdmissionPolicy.rejection(for:inFlight:)` checks `breakerOpenUntilByRoot[root] > now` before `rootBackgroundCap`/`byteBudget` — a breaker-open root reports `providerBreakerOpen` rather than `rootBackgroundCap`, so `op=materialization.admission phase=blocked` remains truthful (`Otos/Services/MaterializationCoordinator.swift:613`).

**State machine (still on the coordinator):**

* On `finishOperation(id:result:)` where `result.outcome == .providerUnavailable`:
  `streak[root] += 1; if streak >= threshold { breakerOpenUntil[root] = now + cooldown; streak = 0 }`
  Log `op=materialization.providerBreaker phase=opened rootPath=… streak=2 cooldownMs=60000` at `.notice` (so `log stream --level info` captures it; `§4d` proved `.debug` is never persisted).

* On `finishOperation` where `result.isMaterialized` or `result.outcome == .served-equivalent`:
  `streak[root] = 0; breakerOpenUntil[root] = nil` and log `phase=closed`.

* On `schedulePass()` / `selectedPendingPriority()`:
  Before scanning `backgroundQueue`, filter any `id` where `breakerOpenUntil[id.libraryRootPath] > now` → count into `rejections[.providerBreakerOpen]`. Those IDs stay in `pendingByID`/`backgroundQueue` (no dequeue) and are re-evaluated on the next `wake()` or when the `breakerCooldown` fires a single `Task.sleep` → `wake()`.

* `activeRequestCount(under:)` already scopes to `device||background` waiters; breaker-open pendings still count as active (they are queued demand the eject drain must see). `stateSnapshot()`/`AdmissionSnapshot` add `breakerOpenRoots: Set<LibraryRootPath>` for `diagnosticSink` and for `EnrichmentCoordinatorWorkSelection` to avoid pointlessly re-claiming the same root while the breaker is open.

**Pacing honesty:** `EnrichmentCoordinatorCompletion.retryWorkIfNeeded()` keeps `[15,60,300,900] → ledger 900` for both `timedOut` and `providerUnavailable` — the breaker is an admission-level suppression, not a second back-off schedule. The breaker makes the fast definite failure visible in one place; the ledger keeps the existing long-tail pacing. No change to `timeout`/`pollInterval`/`requestRetryInterval`.

**Concurrency:** all breaker state is actor-isolated; the cooldown wake is a single `Task { [weak self] in try await Task.sleep(for: cooldown); await self?.wake() }` stored as `breakerWakeTask` and cancelled on `shutdown()` or on successful `closed`.

**Instrumentation delta (one line each, `.notice`):**

```
op=materialization.request phase=failed providerMs=… rerequestCount=… outcome=providerUnavailable …
op=materialization.providerBreaker phase=opened|closed rootPath=… streak=…
op=materialization.admission phase=blocked reason=providerBreakerOpen rejected=N …
```

**Tests:**

* `FileMaterializationTests.providerUnavailableShortCircuitsAfterTwoConsecutiveProbes` (done) + `singleTransient…DoesNotShortCircuit` (done).
* New `MaterializationCoordinatorProviderBreakerTests`: inject executor that returns `.providerUnavailable`; enqueue 8 background requests on one root; expect exactly 2 physical dispatches (`k=2` per file → `streak=2` → breaker open) then `schedulePass` emits `providerBreakerOpen rejected=6` and `inFlight=0`; after `cooldown` advance, the third file is admitted. Also `mixedOutcomeResetsStreak` (`providerUnavailable, materialized, providerUnavailable` never opens).

### 5.5 What is explicitly not added

* No new actor/protocol/cache/pool. `FileMaterialization` keeps the one-URL mechanism and the probe; `MaterializationCoordinator` keeps admission/suppression; `EnrichmentCoordinator` keeps window/ledger.
* No `FileProviderManager` integration — `startDownloadingUbiquitousItem` already fires on OneDrive and keeps the vendor-agnostic path (`ADR 0008 §6`); identifier-keyed provider APIs are provider-specific and add a second trigger with no measured win.
* No persistent breaker. `providerNotServing` is transient (user can re-auth OneDrive mid-session, `docs/research/2026-08-07-plan-0065-stage3-verification.md:22`). Process-local cooldown is the right scope.

## 6. Track B — Operational safety: the journal is the truth, the script is a reader

### 6.1 Correct contract

*The only proof that an import or reorganization is active is a durable journal row that survives the `log show` window, a daemon drop, and a reboot.*

Current sources of truth: `active_file_operation` (one row per `copying|readyToPublish|publishedPendingSettlement`, `Otos/Stores/CatalogStoreImportJournal.swift:32`) and `active_reorganization_component`/`active_reorganization_dir` (one per executing component, `Otos/Stores/CatalogStoreReorganizationJournal.swift`). Both advance their root's `namespaceMutationEpoch` before the Store write, so a concurrent scan cannot purge their pending destination.

`script/smoke-run.sh` must never `kill` the single `Otos` process while any row exists — even for a different root — because `kill` terminates all executors (`MaterializationCoordinator` + `MediaImportExecutor` + `LibraryReorganizationRunner`). Per-root messaging is diagnostic only; the safety invariant is global.

### 6.2 Store predicate (authoritative)

Add one Store-owned predicate that both journals share (no new table, no new column):

```swift
// CatalogStore.swift (actor)
func hasActiveOperationalWork() async throws -> Bool  // SELECT EXISTS (SELECT 1 FROM active_file_operation UNION ALL SELECT 1 FROM active_reorganization_component LIMIT 1)
func activeOperationalRootPaths() async throws -> Set<LibraryRootPath> // diagnostic, not a safety gate
```

Called from production only to publish a lightweight `OtosLog.app.notice("op=operationalSafety phase=busy …")`. The script does not call the Store; it reads the same SQLite file.

### 6.3 Script reader — pessimistic, global, and honest

Replace `is_import_active()` in `script/smoke-run.sh:114` with `has_active_operational_work()`:

```bash
has_active_operational_work() {
  if [[ ! -f "$CATALOG_DB" ]]; then return 1; fi
  if ! command -v sqlite3 >/dev/null 2>&1; then return 1; fi
  local out rc
  # WAL reader, never blocks the writer; busy/locked/corrupt → assume active
  out="$(sqlite3 -readonly "$CATALOG_DB" \
    "SELECT source_root_path FROM active_file_operation UNION ALL SELECT root_path FROM active_reorganization_component LIMIT 1;" \
    2>&1)"; rc=$?
  if [[ $rc -ne 0 ]]; then
    printf '%s\n' "$out" >&2  # "database is locked" etc.
    return 0   # pessimistic: failure to prove idle is busy
  fi
  if [[ -z "$out" ]]; then return 1; fi
  printf '%s\n' "$out"
  return 0
}
```

Callers kept: `run_jank()` preflight (`--jank` refuses to start), `cleanup()` trap (leaves app alive, `QUIT_ON_EXIT=0`), and the post-scroll check. Diagnostic wrapper `active_roots_message()` can `SELECT source_root_path … UNION ALL SELECT root_path …` to print `busy on root=…` when busy but not on `SMOKE_ROOT`.

Properties preserved: uses the existing `sqlite3+"$CATALOG_DB"` dependency (`registered_roots_message()` already needs it), `WAL` allows concurrent `-readonly`, global safety (any row → don't kill), and `2>&1` capture makes `SQLITE_BUSY`/`SQLITE_CORRUPT`/`missing table` visible instead of silent empty → false-idle.

Tests for the script: a `bats`-less probe already in `e399bda` — insert a fake `active_file_operation` row (or a temp `active_reorganization_component` row) into a temp `catalog.sqlite`, assert `has_active_operational_work → busy`, delete row, assert idle, and assert `sqlite3` returning `5 busy` (simulate with `chmod 000` or a locking `sqlite3` writer) still reports busy.

### 6.4 What is not added

* No log-based fallback. `log show` is the diagnostic path, not the safety path.
* No file lock or PID file. The journal already is the distributed lock that survives crashes and drives recovery (`CopyfileTransfer` and `ReorganizationExecutor` already reconcile orphan staging on `start()`).
* No per-root kill optimization (e.g. "quit is safe if busy root ≠ SMOKE_ROOT") — the process is single-owner; a per-root kill would require a second process boundary that does not exist.

## 7. Track C — Catalog ownership: one gateway, one actor, one scope value

### 7.1 The wrong split to avoid

`file_length`/`type_body_length` are `warnings` (`AGENTS.md` Boundaries). Splitting `CatalogStore.swift` (3909 lines) to silence them creates two writers or a protocol seam that breaks the four facts that must stay atomic on one actor: `namespaceMutationEpoch`, `FilesystemDirtyAccumulator`, `ScanLeaseController` (`ActiveScan{rootPath, rootRowID, leaseGeneration, startNamespaceMutationEpoch}`), and `reorganizationLeases`. Batch `B1` must not delete rows that `I2` is still dirty for, and a stale scan `S1` captured at epoch 7 cannot purge rows when `I2` has advanced the root to epoch 8.

### 7.2 The blank-slate seam

```
RootRegistry.scopePredicate(selection) -> CatalogScopePredicate { rootIDs, importBatchUnixMs, selectsNothing }
         │
         ▼
CatalogQueryGateway (nonisolated enum)   ← pure SQL + Row→model mapping, no @Actor, no DatabaseWriter
  orderedAssetIDQuery / filterOptions / countAssets / fetchStoredAssets / fetchStoredTileDetails
  fetchImportBatches / fetchAssetIDs(inImportBatch:) / fetchAssetIDsMissingBestDate / fetchCaptureWall
         │
         ▼
CatalogStore (actor)                     ← owns timedRead/timedWrite, roots snapshot, lease/epoch/dirty
  func importBatches() async throws -> [ImportBatchSummary] {
    let db = try database(); return try await db.read { try CatalogQueryGateway.fetchImportBatches(db: $0) }
  }
  // … same for every wrapper: capture roots/rowID outside the closure, delegate inside
         │
         ▼
EnrichmentLeaseGateway (nonisolated enum) ← partitioned claim grouping (already exists, keep)
```

*Gateway owns:* `SQLQuery` builders, `Row` → `StoredAsset`/`StoredTileDetail`/`ImportBatchSummary`/`MediaAssetID`, `sqlPlaceholders(count:)`, `orderPlan(for:rootLocal:)` index selection. Never `await`, never `DatabaseWriter`.

*Store owns:* `database()` → `DatabaseWriter`, `timedRead`/`timedWrite` (slow-query `OtosLog.persistence` at `>50ms`), `roots.pathsByRowID` snapshot capture, `scopePredicate` resolution, `notifyCatalogChanged`/`emitPlanningChange`, and the four atomic fields above. Every wrapper captures its snapshot before `await db.read` and passes it into the gateway — so the gateway cannot forget a scope dimension.

*The catalog split invariant:* every scoped read takes the resolved `CatalogScopePredicate`, not bare `rootIDs`. No query can honor one dimension and forget the other (`docs/architecture.md` "Query scope is resolved once"). `3acca7e` already moved `fetchImportBatches`/`fetchAssetIDs(inImportBatch:)`/`fetchAssetIDsMissingBestDate`/`fetchCaptureWall` — the next PR moves the remaining descriptor-scoped reads (`orderedAssetIDs` ×2, `catalogedAssetCount`/`visibleAssetCount`, `filterOptions`, `mediaAssets(for:)`, `mediaTileDetails(for:)`, `metadata(for:)`). Partitioned claim queries stay in `EnrichmentLeaseGateway`.

### 7.3 Diff discipline (blank-slate file set, not a patch)

Target tree (no new dependencies, no new actor):

```
Otos/Stores/CatalogQueryGateway.swift      ← grows (pure, nonisolated)
Otos/Stores/CatalogStore.swift             ← shrinks (actor, orchestration only)
Otos/Stores/EnrichmentLeaseGateway.swift   ← unchanged except partitioned claims if needed
Otos/Stores/CatalogSQLTypes.swift          ← StoredAsset/StoredTileDetail/SQLQuery (keep)
```

*Rule:* a move is a pure cut: SQL text is byte-identical, mapping is byte-identical, behavior is identical. `script/verify.sh` already contains `CatalogQueryGatewayTests`/`CatalogStoreQueryPlanTests`/`CatalogStoreEnrichmentClaimTests` — every move is covered; no test is rewritten to match the new file location, only the import.

### 7.4 What is not added

* No Store actor split (no `CatalogReadActor`/`CatalogWriteActor`). Two actors would need a distributed `namespaceMutationEpoch` and would replace a local `await` with a cross-actor transaction.
* No protocol over `CatalogQueryGateway`. Substitution boundary is not needed; `GRDB.Database` is already the seam tests use (`CatalogStore.Location.inMemory`).
* No normalized batch table. `import_batch_unix_ms` stays a denormalized column on `media_asset`; `GROUP BY` is the batch list (`ARC-044`).

## 8. Cross-cutting — observability, docs, and requirements

* **Logging:** every new terminal stays `.notice` (not `.debug`). `.debug` is never persisted (`docs/research/2026-08-03-post-increment-review-experiments.md §2`). Existing `op=materialization.request phase=dispatched|completed|failed` at `Otos/Services/MaterializationCoordinator.swift:475/510` already carries `providerMs`/`rerequestCount`/`outcome`; add `providerBreaker` open/close at the same level. Smoke `is_import_active` → `has_active_operational_work` conversion is logged as `op=smoke.safety phase=busy|idle source=journal rows=N` so the trap is visible in `script/logs.sh show --last 10m` without `log stream`.

* **ADRs:** `ADR 0008 §6` (cloud materialization policy) addendum: `providerUnavailable` taxonomy and breaker cooldown. `ADR 0020` addendum: operational-safety defers are fulfilled (ADR 0020 last line: "Not interrupting in-progress work … needs the app to publish its own busy state" — this plan publishes it via the journals). `docs/architecture.md` dataflow box gains `providerBreaker` under `MaterializationCoordinator` and `CatalogQueryGateway (nonisolated)` beside `CatalogStore`.

* **Requirements:** `docs/requirements.md` `ARC-034`/`ARC-036`/`ARC-048`/`ARC-051` each gain a row: `providerUnavailable` distinct from `timedOut`, breaker suppresses further background admission on that root, and smoke/reorg never killed while any journal row exists. `script/requirements-authority-check.sh` keeps `Implemented in`/`Tested by` honest — paths must exist.

## 9. Alternatives considered (why this is the blank-slate pick)

**A. Tune `requestRetryInterval` or `timeout` instead of a new outcome.**
Pros: one line. Cons: fixes 040347 only by making every healthy slow 9.1G transfer fail faster. No diagnostic separation. Rejected — the fast refusal is not a slow transfer.

**B. Break at `EnrichmentCoordinator` (skip known-bad identities at claim time).**
Pros: keeps `MaterializationCoordinator` simple. Cons: `EnrichmentCoordinator` would need a shadow admission policy that duplicates `MaterializationCoordinator`'s `backgroundPerRootCap`/`byteBudget` view; two policies diverge. The coordinator that dispatches the physical transfer is the one that should suppress its own queue.

**C. Persistent per-root breaker (table + migration).**
Pros: survives restart. Cons: `ProviderNotServing` is a transient user action (re-auth OneDrive, `2026-08-06` verification); persisting it makes a stale `signed-out` breaker block enrichment after relaunch with no in-memory way to observe that the provider recovered. Process-local cooldown plus a single probe on next admission is simpler and correct (`ADR 0008` lifecycle).

**D. Split `CatalogStore` into two actors with a protocol.**
Pros: smaller files. Cons: `namespaceMutationEpoch` and `ScanLeaseController` must agree on one generation counter; splitting them introduces a cross-actor transaction exactly where the current code's correctness lemma lives (`scanCanDelete` checks `owns(scan) && epoch == startNamespaceMutationEpoch`). The gateway-enum split achieves the file goal without touching the correctness lemma.

## 10. Implementation order (three PRs, each lands on main green)

**PR 1 — Materialization breaker.** Files: `Otos/Services/FileMaterialization.swift` (no change beyond landed `27798c3`), `Otos/Services/MaterializationAdmissionPolicy.swift` (+`providerBreakerOpen`), `Otos/Services/MaterializationCoordinator.swift` (+3 fields + `breakerWakeTask` + `schedulePass` filter + `finishOperation` streak), `OtosTests/MaterializationCoordinatorProviderBreakerTests.swift` (new). Docs: `docs/adr/0008-…md` addendum + `docs/architecture.md` box. Verify: `script/verify.sh` (579+ tests), live OneDrive `ProviderNotServing` re-run (`040347` `providerMs≈2000` not `120133`) and healthy `ProviderServing` re-run (no breaker open), `script/profile.sh` to prove no `mainThreadStall` regression.

**PR 2 — Operational safety hardening.** Files: `Otos/Stores/CatalogStore.swift` (+`hasActiveOperationalWork()`/`activeOperationalRootPaths()`), `script/smoke-run.sh` (`has_active_operational_work()`, pessimistic `rc≠0 → busy`, `UNION ALL active_reorganization_component`, `registered_roots_message()` unchanged), `script/check-production-data-untouched.sh` (no-op). Docs: `docs/adr/0020-…md` defers fulfilled, `docs/requirements.md` smoke row. Verify: script probe (fake journal row → busy, delete → idle, `SQLITE_BUSY` simulation → busy) + `script/smoke-run.sh --jank` preflight/refusal and post-scroll leave-alive.

**PR 3 — Catalog ownership finish.** Files: `Otos/Stores/CatalogQueryGateway.swift` (+remaining scoped reads), `Otos/Stores/CatalogStore.swift` (wrappers only). No new files. Verify: `script/verify.sh` + `script/lint.sh 0 serious` (file splits already at 0 serious) + `script/requirements-authority-check.sh`.

Each PR deletes no production data, adds no migration, and keeps `script/build.sh BUILD SUCCEEDED`.

## 11. Verification

* **Unit:** existing `FileMaterializationTests` + new `MaterializationCoordinatorProviderBreakerTests` + `CatalogQueryGatewayTests` (already covers every gateway path). No substring-asserting tests (CI forbids them).
* **Field (recorded precondition):** every capture begins with direct `open()+read(4096)` probe under `SMOKE_ROOT`; result (`ProviderServing` vs `ProviderNotServing`) is logged as the first line. The dead-provider capture must show `outcome=providerUnavailable rerequestCount=2` and breaker `rejected=N` with `inFlight` recovering in one cooldown, not `outcome=timedOut rerequestCount=112`.
* **Profiling:** `script/profile.sh "Time Profiler" 10s` through a 6-cycle smoke scroll; compare worst `projectionMs`/`applyCallMs` before/after — materialization changes must not regress grid jank (Pike's "measure before optimizing").
* **Authority:** `script/verify.sh` is the gate (requirements-authority + lint + build + test + production-data-untouched). `docs/requirements.md` and `docs/adr/` are updated in the same PR as the behavior.

## 12. Risks and rollback

* Breaker threshold `2` / cooldown `60s` are tuning knobs, not invariants. If OneDrive's post-re-auth probe still returns one transient `ETIMEDOUT` before serving, the breaker would false-open; the second probe's `inconclusive` reset already handles the transient, and the breaker only counts `providerUnavailable`, not `inconclusive`. Rollback is one revert (remove the three fields and the `providerBreakerOpen` case); behavior returns to `providerUnavailable`-per-file (2s per file) without reopening the 120s path.
* `SQLITE_BUSY → busy` is safe by construction (never kills when unsure) but can stall a smoke run that races an import commit. The stall is visible (`busy on root=…`) and resolves in one commit — preferable to a mid-copy kill.
* Catalog gateway moves are pure cuts; rollback is `git revert` of the PR — no migration to undo.

## 13. Definition of done

* All three PRs landed on `origin/main`, branch/worktree removed, `git status` clean.
* `script/verify.sh` green on the merge commit, with the dead-provider field log and the healthy-provider field log attached to the PR as `docs/research/` captures.
* `docs/architecture.md` + `docs/requirements.md` + `docs/adr/0008` + `docs/adr/0020` + this plan's retirement (delete `docs/plans/0068-…md`) in the same PRs as the behavior.
* DoD report on each PR (`script/dod-report.sh`) with instrumentation excerpts and code-smell notes.
