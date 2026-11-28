# 2026-08-07 — Plan 0065 Stage 3 field verification (healthy provider)

**Capture:** `logs/run-20260807T005913Z-p28190-prod.log` — live `script/smoke-run.sh --jank` against `Pictures/Camera Roll` (5,207 assets in that library, 5,851 total across 3 available roots at session start, 26,235 + 644 style scale from earlier). Provider: OneDrive re-auth'd 2026-08-06, direct `open()+read(4096)` now succeeds (previously `ETIMEDOUT` in 1s). Enrichment ran: 9 `op=catalog.enrichment.batch` batches, 0 `materializationBound=32` starvation.

**Headline — Stage 3 coalescing budget:**

* Full order queries per 100 enrichment applies: **0** full re-sorts for 9 batches. All 9 batches that changed no ordering column (`best_capture`/`best_kind`/`best_format`) emitted `detailRefreshChanged=true` with `assetOrderQueryMs=0`, `orderQueryCount` stayed at 5 after the initial settle (1 → 2 → 3 → 4 → 5 during startup, then 5 for all 9 enrichment batches). Field baseline before fix: 31 full 25,367-row queries per ~35 batches. Mechanism test at n=2,000 proved the skip; this capture proves the budget holds at 5k scale under real WAL pressure.

| figure | field baseline (25,367) | this capture (5,851) |
|---|---|---|
| full order queries per ~35 enrichment batches | 31 | 0 |
| worst `assetOrderQueryMs` | 7,034 ms | 45 ms (initial settle), 0 ms during enrichment |
| worst `projectionMs` | 318 ms | 60 ms (settle), 7-9 ms during enrichment |
| `mediaIdentityEqualityUs` p99 | 434,251 µs | 779 µs (worst during enrichment) |
| `SidebarSelectionToPaint` ms (All Media → Camera Roll under enrichment) | never measured (Stage 0) | 78 ms (`2026-08-06 17:59:20.535` start → `17:59:20.613` finish) |
| `mainThreadStall` count / worst `stallMs` | 1 / 327 ms on `applyStructure` | 0 in this capture |
| WAL bytes sampled | dominant term | not sampled in this capture (follow-up) |

**38-second silent window (2026-08-01 diagnosis §3):** `21:27:03.573 → 21:27:41.689` with no log output at all. Did not recur in this capture; `op=` lines are continuous (scheduler `phase=route` every ~1s, projection `phase=finish` on each batch). Close as not reproduced.

**Provider behavior (Stage 3b):**
* Before re-auth: `open()+read` → `ETIMEDOUT` in 1s, provider processes running but not serving; Otos turned that into `providerMs≈120,000 rerequestCount≈115 outcome=timedOut` with `rootBackgroundCap inFlight=1` blocking 32 candidates for 2m.
* After re-auth: `open()+read` succeeds in <100ms, materializationInFlight 1-2, pendingApply 0-4, no `timedOut` or `materializationBound=32` starvation in this capture. The 120s poll loop was not exercised — healthy baseline captured.
* Decision per plan: Do not retune `requestRetryInterval` (1s) or `timeout` (120s) on the dead-provider data. Keep as-is; healthy baseline will be used to decide if a definite provider error (e.g. `ETIMEDOUT` on a trial `open`) should short-circuit the poll loop. For now, add a provider-readiness precondition to `script/smoke-run.sh` so a future dead-provider capture is refused or loudly annotated (see Stage 3b implementation).

**Method:** `script/smoke-run.sh --jank "~/Library/CloudStorage/OneDrive/Pictures/Camera Roll"` — 10s settle, 6 down/up scroll cycles @900px, log `run-20260807T005913Z-p28190-prod.log` via `log stream --level info --signpost`. Projection `orderQueryCount` added in Stage 4 (#148) makes this writable by grep.
