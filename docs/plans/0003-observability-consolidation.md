# Plan 0003 — Observability Consolidation (OSLog + Instruments only)

> Non-authoritative plan. Delete when done.
> Execution order: **third** — after the 0002 bug fixes (small diffs first),
> before the big refactors (0005–0007) so they don't have to migrate
> diagnostics call sites twice. Also materially shrinks `CatalogStore`
> (41 diagnostics call sites) ahead of its decomposition.

## 1. Owner decisions (2026-07-08)

- **No human will ever read any logs.** Instrumentation earns its place only
  if the agent mechanically consumes it, or Instruments consumes it.
- **If we don't use Instruments, we leave it out.** Verified: the agent *can*
  drive Instruments headlessly (`xcrun xctrace record --template … --attach
  Otos`, then `xctrace export`) — so interval signposts stay, but only where
  a template would actually be pointed at them.
- The agent reads runtime logs via unified logging
  (`log show/stream --predicate 'subsystem == "net.melisma.Otos"'`), for both
  production and Xcode-launched runs. Console output is not available to the
  agent — that is fine; unified logging is process-independent.

## 2. Current inventory (verified by inspection)

| Mechanism | Size / spread | Consumer today |
| --- | --- | --- |
| `OtosLog` (10 categories) + `Logger` calls | everywhere | agent via `script/logs.sh` ✅ |
| Interval signposts (`beginInterval`) | ~40 distinct names | Instruments (rarely), log stream noise |
| **Bare event signposts** (`emitEvent`) | 23 distinct names across 8 files | nobody |
| **`CatalogDiagnostics` JSONL actor** ([Support/Diagnostics.swift](../../Otos/Support/Diagnostics.swift)) | ~56 `record` sites in 11 files (41 in `CatalogStore` alone); session files, retention pruning, lazy handles | `script/catalog-diagnostics.sh`, smoke `--verify`, diagnostics-gate tests |
| **`GridTelemetry`** counters ([Support/GridTelemetry.swift](../../Otos/Support/GridTelemetry.swift), 150 lines) + snapshot task ([ViewModels/CatalogWindowViewModelGridTelemetry.swift](../../Otos/ViewModels/CatalogWindowViewModelGridTelemetry.swift), 82 lines) + termination semaphore flush | 4 call-site files | one JSONL row nobody reads |
| `MainRunLoopStallMonitor` ([Support/UIJankDiagnostics.swift](../../Otos/Support/UIJankDiagnostics.swift), 223 lines) | grid handoffs, operations, 100 ms stall detection | writes JSONL rows |
| `RunContext` | session id/kind | keep (tiny, useful for correlation) |

The split is itself documented complexity ("coarse JSONL for boundaries,
signposts for high-frequency, counters for hot paths") — three bespoke sinks
replicating what unified logging already does.

## 3. Target design

**One facade (`OtosLog`), one sink (unified logging), plus interval signposts
solely as Instruments annotations.**

### 3.1 Logging policy

- Levels: `.error`/`.fault` for failures and stalls (always persisted);
  `.notice` (default level — persisted to disk by the log store) for
  operation boundaries the agent greps after a run; `.info`/`.debug` for
  detail available during `log stream` or shortly after via `log show`.
  Rule of thumb: **anything the agent must find hours later is `.notice` or
  above.**
- **Everything is `privacy: .public`.** No human reads these; the agent must.
  Unsandboxed local dev tool, user's own machine, no secrets in media facts
  (AGENTS.md already permits paths/filenames). Sweep existing calls: any
  interpolation without `.public` gets it.
- Structured convention (greppable, not a schema): start the message with a
  stable `op=` token, then `key=value` pairs — e.g.
  `op=structuralApply items=1204 inserted=12 removed=0 applyMs=8`.
  This is what `log show --style ndjson | jq` slices on.

### 3.2 What is deleted

1. **`CatalogDiagnostics` actor + `CatalogDiagnosticEvent`** — every
   `await diagnostics?.record(operation:phase:fields:)` becomes one `OtosLog`
   call at the appropriate level with the same fields inlined
   (`op=<operation> phase=<phase> k=v …`). Mechanical: 56 sites; the
   `diagnostics` constructor params/properties and plumbing through
   `CatalogStore`, `CatalogProjection`, `EnrichmentCoordinator`,
   `CatalogWindowViewModel`, monitors then disappear. Note: many sites are
   `await`-ing an actor today — removing the `await` also removes actor-hop
   latency from hot store paths (a real, if small, win).
2. **`GridTelemetry` + the ViewModel snapshot/termination machinery** —
   delete both files, the `gridTelemetryTask`/`didRecordTerminationGridTelemetry`
   properties, the `NSApplication.willTerminateNotification` hook in
   `OtosApp`, and the counter call sites (4 files). The one genuinely
   diagnostic counter — the no-blank **watchdog** — already logs at `.error`
   in `MediaAssetTileView.clearPaintedImage`; keep that log line (upgrade to
   include `op=paintWatchdog`).
3. **All 23 bare `emitEvent` signposts.** For each: if the adjacent `Logger`
   line already covers it (most do), just delete; if not, add/upgrade a log
   line. None of them is consumed by any Instruments workflow.
4. **Scripts/tests of the deleted machinery**: `script/catalog-diagnostics.sh`;
   `CatalogDiagnosticsTests.swift` (365 lines); the diagnostics-gate
   assertions inside `script/smoke-run.sh --verify` (see §3.4);
   `BrowserDiagnosticsSourceHygieneTests` (already deleted by plan 0001 —
   coordinate, don't double-delete).
5. Requirement rows referencing the JSONL machinery (performance-evidence guidance in AGENTS.md,
   diagnostics rows) — updated to the new tooling.

### 3.3 What is kept (and why it survives the "do we use it" test)

- **Interval signposts, pruned to operations a template inspects**: keep
  `MediaGridStructuralApply`, `MediaGridZoomApply`, `MediaGridLayoutReplace`,
  `CatalogScanEnumerate/BatchWrite/Flush/Reconcile`,
  `CatalogEnrichmentBatchWrite`, `CatalogStoreOrderedAssetIDQuery` +
  the other three store query intervals, `CatalogWindowPublication/StateBuild/
  StateApply`, `FilesystemEventBatch`. Delete intent-wrapper intervals that
  duplicate an inner interval (`Catalog*Intent` pairs) unless a trace has used
  them. Criterion for the future (goes in the ADR): *a new signpost must name
  the Instruments question it answers.*
- **`MainRunLoopStallMonitor`** — 100 ms main-thread stall detection is the
  repo's hang budget made observable; keep it, but its sink becomes
  `OtosLog.performance.fault("op=mainThreadStall stallMs=… lastOp=…")`
  instead of JSONL. Grid handoff context stays in-memory as today.
- **`RunContext`** — logged once at startup (`op=sessionStart session=…`),
  giving the agent a correlation anchor in `log show` output.
- **`script/profile.sh`** — unchanged (xctrace record). Add
  `script/profile-export.sh <trace>` (thin wrapper over
  `xctrace export --input … --toc/--xpath`) so trace parsing is one command.
- **`script/logs.sh`** — rewritten: subcommands `stream` (current behavior),
  `show --last <t>` (post-hoc, `--style ndjson`, default `--info --debug`),
  both predicate-filtered on the subsystem. This is the agent's primary
  window; document in AGENTS.md.

### 3.4 Migration of dependent tooling

- `script/smoke-run.sh --verify` currently locates the newest diagnostics
  JSONL by PID and checks for a successful `ensureLibrary` event. Replace
  with: `log show --last <window> --predicate 'subsystem == "net.melisma.Otos"
  AND eventMessage CONTAINS "op=ensureLibrary"' --style ndjson` filtered by
  the app PID it launched; assert one `phase=finish` line. The check must use
  `.notice`-level logging in the store's ensure path so it is reliably
  persisted.
- The smoke summary section that pretty-prints JSONL is deleted or pointed at
  `logs.sh show`.

## 4. New ADR

`docs/adr/0015-observability.md` (slot reserved by plan 0001): one sink
(unified logging, all-public, level policy above), interval signposts as
Instruments annotations only with the "names the question" rule, the agent
workflows (`logs.sh stream/show`, `profile.sh` + export), and the explicit
rejections: bespoke JSONL sinks, event signposts, scalar counter snapshots —
each with the one-line reason (no consumer).

## 5. Execution order within this plan

1. Rewrite `logs.sh`; add `profile-export.sh`. (Tooling first so verification
   of later steps uses it.)
2. Sweep `privacy:` to `.public`; introduce the `op=` message convention on
   the lines the smoke check and stall monitor rely on.
3. Migrate the 56 `diagnostics?.record` sites file-by-file (Store last, as
   the biggest); delete the actor, plumbing, tests, script.
4. Delete `GridTelemetry` + ViewModel extension + termination hook.
5. Delete/absorb the 23 `emitEvent` sites; prune interval signposts per §3.3.
6. Migrate smoke `--verify`; run `script/smoke-run.sh --verify` +
   `script/logs.sh show` as evidence.
7. Stall monitor sink swap.
8. ADR 0015; requirements-row updates; AGENTS.md command section update.

## 6. Acceptance criteria

- `rg "CatalogDiagnostics|GridTelemetry|emitEvent" Otos/ OtosTests/` → empty
  (except ADR/plan text).
- `script/smoke-run.sh --verify` passes using `log show` only; no JSONL files
  are created anywhere by the app.
- `script/logs.sh show --last 5m` after a manual run returns ndjson the agent
  can `jq` (spot-check documented in the PR).
- An `xctrace record` + `profile-export.sh` round-trip on a scroll workload
  shows the kept signpost intervals (evidence attached to the PR).
- `verify.sh` green; app behavior unchanged.

## 7. Risks

- **Losing post-crash evidence**: JSONL survived crashes via immediate append;
  unified logging persists `.notice`+ reliably but `.debug` is best-effort.
  Mitigation: everything crash-relevant (errors, stalls, operation
  boundaries) is `.notice` or above by policy.
- **Store test coupling**: some store tests may assert diagnostics records
  exist. Inventory first (`rg "diagnostics" OtosTests/`), rewrite those
  assertions against observable behavior or the injected logger boundary, or
  delete where they only tested the sink.
- **Log volume**: `.debug` lines are cheap and dropped by default persistence;
  the `.notice` set is the bounded old "coarse JSONL" set. No per-frame logs
  are added (existing policy unchanged).
