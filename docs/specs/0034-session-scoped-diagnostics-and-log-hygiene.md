# Spec: Session-Scoped Diagnostics And Log Hygiene

## Classification

- Work type: Process/tooling and diagnostics refactor.
- Current requirement IDs: FND-002, FND-006, FND-025, FND-035, FND-041,
  FND-070.
- Future idea or candidate links explicitly requested by the user: later
  `PLAN.md` phases for wait/exec timing, stall attribution, animated grid
  applies, claim batching, query-intent generation, filter-menu sharing, symlink
  add normalization, and sort-key separator migration.
- ADRs: none. This increment changes debug diagnostics and scripts, not catalog
  truth, media I/O policy, grid rendering behavior, or persistence schema.

## Problem

A real-library smoke run produced enough evidence to diagnose jank and flicker,
but the evidence was hard to trust quickly:

- `console.log` was a repo-root, untimestamped capture with 47,405 lines.
- The debug JSONL diagnostics file was one append-only
  `catalog-diagnostics.jsonl` shared across sessions and had grown to 197,639
  records.
- High-cardinality records dominated the signal: 89,864 `catalog.scan.issue`
  rows for the same `relativePathUnavailable` condition, 50,682 enrichment query
  rows, 46,614 tile-detail query rows, and tens of thousands of per-tile console
  debug lines.
- Normal scroll-driven `CancellationError` from visible tile detail reads was
  logged like a real error.

The user-facing goal is not to add a product scan-health UI. The goal is a
clean agent/developer evidence path: every run writes session-scoped artifacts,
durable JSONL stays coarse and bounded, and normal cancellation stops polluting
failure evidence.

## Scope

In scope:

- Add a process `RunContext` that identifies test vs app runs and names sessions.
- Change default debug diagnostics to per-session files and prune old files.
- Remove the legacy unbounded diagnostics file at diagnostics startup.
- Route script log-stream captures into session-named files under `logs/`.
- Stop leaving `console.log`, `run.log`, or `lldb.log` in the repo root.
- Demote or delete high-cardinality console and JSONL spam.
- Aggregate repeated scan issues into scan-level diagnostics.
- Treat visible tile detail `CancellationError` as normal cancellation.
- Include useful error text in generic catalog/projection error logs touched by
  this increment.
- Make smoke `--verify` inspect session diagnostics so it cannot pass unless the
  seeded library root was consumed.
- Address recent review feedback by migrating existing thumbnail paths/files
  when startup normalizes an older saved symlink-spelled root.
- Update tests and living docs for the new diagnostics contract.
- Delete `PLAN.md` before final cleanup, per the user's follow-up instruction.

Out of scope:

- Wait/exec query timing splits.
- Main-run-loop stall operation attribution.
- Animated structural grid applies and thumbnail flicker behavior changes.
- Enrichment claim batching, WAL checkpoint tuning, and SQLite synchronous
  changes.
- Query-intent generation, shared filter menu, sort-key separator migration, and
  add-path symlink normalization.
- User-facing scan health UI.

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected: `Diagnostics.swift`, run/log scripts,
      scanner/store/tile/grid logging paths, diagnostics tests, requirements,
      performance process docs, onboarding, and docs index.
- [x] Captured user guidance is restated as precise requirements for user
      verification below.
- [x] Observable current requirements and acceptance examples are listed.
- [x] Future ideas and unimplemented requirement candidates are separated from
      `docs/requirements.md`.
- [x] Roadmap and planning documents are not used for this task; `PLAN.md` is
      user-provided scope input and will be deleted after implementation.
- [x] Ownership, side effects, persistence, cancellation, errors, progress,
      privacy, instrumentation, and tests are addressed.
- [x] At least three alternatives are compared.
- [x] Refactor retirement proof is defined.
- [x] A stale-document audit is defined for affected requirements, process docs,
      onboarding, indexes, scripts, specs, and backlinks.
- [x] A code-comment accuracy audit is defined for touched diagnostics,
      scanner, store, and AppKit-boundary file guides.
- [x] Performance/jank evidence is defined as log-volume and diagnostics-shape
      evidence; no runtime tuning is performed in this phase.
- [x] Open questions are answered or out of scope.

## Captured Requirements For User Verification

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| SLD-001 | Tooling | Debug diagnostics files shall be session-scoped and clearly labeled by run kind instead of appending every run to one global JSONL file. | Current | `docs/requirements.md`, this spec |
| SLD-002 | Tooling | Run/log scripts shall write compact unified-log captures to ignored, timestamped files under `logs/` and shall stop producing bare repo-root `console.log`, `run.log`, or `lldb.log`. | Current | `docs/requirements.md`, this spec |
| SLD-003 | Non-functional | Durable JSONL shall not record high-frequency tile detail queries, enrichment candidate queries, or repeated scan issues unless they are slow or aggregated. | Current | `docs/requirements.md`, this spec |
| SLD-004 | Regression | Visible tile detail cancellation during scrolling shall not be logged as an error. | Current | `docs/requirements.md`, this spec |
| SLD-005 | Privacy | Diagnostics may include developer-useful media paths when needed, but repeated per-path issue spam shall be bounded to a small set of examples plus aggregate counts. | Current | `docs/requirements.md`, this spec |
| SLD-006 | Process | The proposed `PLAN.md` shall be deleted once this increment's implemented scope is done. | Current | This spec |
| SLD-007 | Tooling | Smoke `--verify` shall fail unless the launched app run records a successful `catalog.library.ensure` diagnostic for the seeded root. | Current | `docs/requirements.md`, this spec |
| SLD-008 | Regression | Startup normalization of an older symlink-spelled root shall migrate existing thumbnail paths and files to the normalized-root deterministic name. | Current | `docs/requirements.md`, this spec |
| SLD-009 | Candidate | Later phases shall add wait/exec timing, stall attribution, flicker remediation, write-burst remediation, and correctness cleanups as separate PRs. | Candidate | `PLAN.md` until deleted; this spec out-of-scope list |

## Architectural Alternatives

### Alternative A: Keep The Global File And Add Better Summary Scripts

Pros:

- Smallest code change.
- Existing diagnostics tests and scripts keep their shape.

Cons:

- Historical maxima continue to pollute current-run analysis.
- Cleanup remains manual and easy to forget.
- Test and app runs cannot be separated by filename.

Failure modes:

- Agents keep diagnosing the wrong run.
- Log volume grows until basic summaries become slow or misleading.

### Alternative B: Session Files Plus Bounded Retention

Pros:

- Each app/test run has its own artifact.
- Retention is simple and local to the diagnostics owner.
- The existing `CatalogDiagnostics(outputURL:)` injection remains intact for
  focused tests.
- No catalog persistence or user data migration is involved.

Cons:

- Scripts and docs must move to the same naming vocabulary.
- Tests that expected shared diagnostics to be disabled under XCTest must be
  updated.

Failure modes:

- A bad pruning predicate could remove injected test files if it is not limited
  to default diagnostics startup and file naming.
- Multiple launches in the same second could collide without a PID suffix.

### Alternative C: Remove Durable JSONL And Use Only Unified Logs

Pros:

- Eliminates JSONL file growth entirely.
- One logging system to inspect.

Cons:

- Loses machine-checkable summaries used by `script/catalog-diagnostics.sh`.
- Unified logs are harder to persist and parse after a smoke run.
- Run-loop stalls and projection summaries become less durable evidence.

Failure modes:

- Future performance work loses the exact scalar evidence that exposed the
  current issue.

## Selected Approach

Choose Alternative B. Session-scoped JSONL keeps the current useful diagnostic
shape while fixing the main evidence failure: unrelated runs and spam hid the
current-run signal. It is the simplest correct architecture because
`CatalogDiagnostics` already owns file creation and can own retention without a
new service, database, cache, or cross-process coordinator.

High-frequency telemetry remains in OSLog/signposts. JSONL remains for coarse,
bounded, machine-checkable facts: projection summaries, scan summaries,
availability transitions, failures, actual stalls, and slow query outliers.

## Interfaces, Ownership, And Data Flow

- `RunContext` is a nonisolated support helper. It reads process environment,
  detects test runs, and computes a stable process session ID once.
- `CatalogDiagnostics.shared` remains the single default diagnostics instance.
  Its default path becomes
  `Application Support/<bundleID>/Diagnostics/catalog-diagnostics-<sessionID>-<runKind>.jsonl`.
- `CatalogDiagnostics` owns default diagnostics retention and legacy file
  deletion at startup. Injected `outputURL` instances used by tests do not prune
  unrelated directories.
- `CatalogScanner` owns scan issue aggregation for a single scan and passes a
  compact summary through the existing scan finish diagnostic.
- `CatalogStore` keeps unconditional signposts but records tile-detail and
  enrichment-candidate JSONL only when the total time crosses a named slow-query
  threshold.
- `MediaAssetCollectionView` treats cancellation as normal in the tile detail
  reader and keeps generic failures visible.
- `script/build_and_run.sh`, `script/capture-run.sh`, `script/smoke-run.sh`,
  `script/test.sh`, and `script/logs.sh` share the same `logs/` capture
  directory and session naming.

## Retirement Proof

- `catalog-diagnostics.jsonl` is deleted by default diagnostics startup.
- Repo-root `console.log`, `run.log`, and `lldb.log` are ignored and removed from
  the working tree.
- Per-tile debug lines in `MediaAssetTileView` are deleted while signposts remain.
- Per-query JSONL and console debug lines for tile-detail and enrichment
  candidate queries are thresholded.
- Per-file `catalog.scan.issue` JSONL events are replaced by aggregate scan
  finish fields and bounded examples.
- The previous test expectation that shared diagnostics are disabled under tests
  is retired because test sessions now get `-test` filenames.

## Living Documentation And Comment Audit

Update:

- `docs/requirements.md`: session diagnostics, log capture, JSONL boundedness,
  cancellation-aware errors.
- `docs/process/performance.md`: `logs/` capture names and per-session JSONL.
- `docs/process/development-workflow.md`: seeded smoke artifact paths.
- `docs/onboarding.md`: observability and smoke-launch narrative.
- `docs/index.md`: add this spec.
- File guides/comments in `Diagnostics.swift`, `CatalogScanner.swift`,
  `CatalogStore.swift`, `MediaAssetCollectionView.swift`, and
  `MediaAssetTileView.swift` if their current comments become stale.

Unaffected after audit:

- ADRs: no current ADR decision scope changes in Phase 0.
- Roadmap/planning docs: not authoritative for this increment.
- Templates: no template wording changes required.

## Instrumentation And Performance

- Keep OSLog categories and signposts for UI, Catalog, FileAccess, Persistence,
  Metadata, Thumbnails, and Performance.
- Keep `catalog.projection.window` unchanged because it was bounded and useful.
- Keep `ui.mainRunLoop.stall` unchanged in this phase.
- Add/retain slow-query JSONL only for `catalog.store.query.tileDetail` and
  `catalog.store.query.enrichment` when `queryMs > 50`.
- Scan issue diagnostics become scan-level aggregate fields plus at most ten
  path examples per `(kind, error)` key.
- Verification uses `script/catalog-diagnostics.sh check`, focused tests, and
  targeted script/log file assertions. A full jank profile is out of scope until
  later phases change runtime behavior.

## Code-Smell Review

- Diagnostic payload sprawl: addressed by deleting per-tile debug logs and
  aggregating repeated scan issues.
- MainActor gravity: avoided by leaving tile/detail work ownership unchanged and
  not adding JSONL tasks in UI hot paths.
- State duplication: avoided by keeping run identity in one `RunContext`.
- Ambiguous names: new constants name retention count and slow-query threshold.
- Test coupling: tests should assert filenames, pruning, aggregation, and
  threshold behavior rather than exact incidental log strings.
- Privacy: scan issue examples are bounded; no secrets or binary payloads are
  logged.

## Acceptance Criteria

- Default diagnostics filenames include session ID, PID, and `prod` or `test`.
- Default diagnostics startup removes the legacy global JSONL file and retains
  only the newest ten diagnostics files per run kind.
- `CatalogDiagnostics(outputURL:)` remains usable by tests without unexpected
  pruning.
- `script/build_and_run.sh --logs`, `--telemetry`, `script/capture-run.sh`,
  `script/smoke-run.sh`, `script/test.sh`, and `script/logs.sh` use ignored
  session-named files under `logs/` when they capture to disk.
- Tile debug spam is gone while tile signposts remain.
- Tile-detail and enrichment-candidate query JSONL appears only for slow queries.
- Scan issue spam is summarized on scan finish with aggregate counts and bounded
  examples.
- Scroll-driven visible-detail cancellation returns an empty detail map without
  an error log.
- `script/smoke-run.sh --verify` proves the seeded root was consumed through the
  launched app run's `catalog.library.ensure` diagnostics.
- Startup root normalization migrates deterministic thumbnail paths/files instead
  of leaving old-spelling thumbnail files orphaned.
- `PLAN.md`, `console.log`, `run.log`, and `lldb.log` are absent from the final
  tree.

## Verification

- Local checks: `script/verify.sh`.
- Focused tests: diagnostics session naming/retention, diagnostics script
  compatibility, scanner issue aggregation, store query slow-threshold behavior,
  and tile detail cancellation behavior.
- Performance/log evidence: targeted app/test launch enough to prove session
  artifacts; seeded smoke if the real library root is available in the
  environment.
- Stale-document audit: docs listed above updated or explicitly reported
  unaffected.
- Code-comment accuracy audit: touched file guides reviewed for current truth.
- CI expectations: remote fast gate must pass or report an external GitHub
  Actions blocker exactly.
