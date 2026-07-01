# Spec: Code Quality Maintainability Audit

## Classification

- Work type: Refactor / process / documentation / test robustness
- Current requirement IDs: FND-001, FND-002, FND-006, FND-011, FND-014,
  FND-019, FND-025, FND-063, FND-068, FND-069
- Future idea or candidate links explicitly requested by the user: none
- ADRs: none

## Problem

The codebase had three quality smells that made future changes harder to trust:

1. Living documentation drifted away from code. `FileMaterialization` comments and
   Spec 0016 still said the detector was not wired up even though enrichment now
   calls it; ADR 0002 and Spec 0004 still described the old `DatabaseQueue` plus
   old resident catalog model as current; a root-level superseded planning note
   was still linked; and a duplicate root agent-instructions mirror sat outside
   the canonical `AGENTS.md` entry point.
2. Concurrency escape hatches existed in normal app/test paths. Four
   `@unchecked Sendable` sites remained, and several Store diagnostics paths used
   anonymous fire-and-forget tasks without one named owner.
3. Important async tests relied on repeated `Task.sleep` polling or wall-clock
   debounce timing, especially around Store state, filesystem events, Projection,
   and ViewModel state.

The user explicitly tightened the concurrency bar during this increment:

> I hate any unchecked Sendables. the bar for one is incredibly high. I'd really
> hope we get rid of all of them

That guidance is treated as a current quality requirement for this increment:
target zero `@unchecked Sendable` in production and tests.

## Current Repo State

Inspected before implementation:

- `CatalogStore.swift` is the largest source file and still has a file-length
  smell, but splitting it is out of scope for this increment.
- `FileMaterialization.swift` had two obsolete comments saying the helper was not
  used even though `MediaEnricher` gates byte reads and `EnrichmentCoordinator`
  calls `FileMaterialization.materialize(_:)`.
- `docs/index.md` described Spec 0016 as an unused detector and linked a
  superseded root planning document.
- Root markdown included a duplicate agent-instructions mirror alongside the
  canonical `AGENTS.md` entry point.
- ADR 0002 and Spec 0004 still presented `DatabaseQueue` and full resident
  per-asset catalog loading as current, despite ADR 0010 and code using
  file-backed `DatabasePool`, Store-owned queries, and no resident per-asset map.
- Four `@unchecked Sendable` sites existed:
  `WatcherState`, `TestingCatalogFilesystemWatcher`, `MediaTileDetailReader`, and
  `LoadedTile`.
- Store, Projection, ViewModel, filesystem-event, and lifecycle tests contained
  broad polling loops or wall-clock sleeps for ordinary state observation.

## Scope

In scope:

- Add this decision-complete spec.
- Update stale current docs and comments.
- Delete the superseded root planning document and duplicate root
  agent-instructions mirror.
- Remove all `@unchecked Sendable` from production and test source.
- Keep the filesystem watcher off-main while replacing lock-backed unchecked
  sendability with standard synchronization.
- Convert `MediaTileDetailReader` to a `Sendable` value.
- Convert `LoadedTile` to ordinary `Sendable`.
- Centralize Store's best-effort diagnostics task escape in one named helper with
  bounded scalar payloads.
- Make enrichment startup stop if `store.start()` fails.
- Add async test helpers for timeouts, event recorders, and manual debounce gates.
- Convert the top timing-heavy Store, filesystem-event, lifecycle, Projection,
  and ViewModel tests away from broad polling where app events exist.
- Add source-hygiene coverage for root markdown, stale materialization wording,
  and zero unchecked sendability in source.

Out of scope:

- Splitting large Store/Persistence files.
- Re-architecting Store, Projection, grid, enrichment, or persistence.
- Changing user-visible UI behavior.
- Changing database schema or app data.
- Eliminating all possible timeout sleeps. Harness timeouts, negative/absence
  assertions, file-diagnostics polling, and production cadence sleeps remain valid
  when they represent the behavior being tested.

## Captured Requirements

| ID | Type | Requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| QA-001 | Process | Living docs and code comments must describe current behavior, not superseded architecture. | Current | `docs/requirements.md`, this spec |
| QA-002 | Architecture | Production and test source must contain zero `@unchecked Sendable` after this increment. | Current | `docs/requirements.md`, this spec |
| QA-003 | Architecture | Any future unavoidable unchecked sendability must be justified in a spec, isolated to the narrowest wrapper, and guarded by source hygiene. | Current process rule | `docs/requirements.md`, this spec |
| QA-004 | Testing | Async tests should wait on owner events, continuations, Observation, or injected gates when such signals exist. | Current | `docs/requirements.md`, this spec |
| QA-005 | Testing | Harness timeouts and explicit absence windows may use `Task.sleep`; ordinary state observation should not poll with sleeps. | Current | `docs/requirements.md`, this spec |
| QA-006 | Architecture | Best-effort diagnostics tasks must have one named helper or explicit owner and capture bounded scalar payloads, not catalog state or asset batches. | Current | `docs/requirements.md`, this spec |

The user guidance above was explicit enough to store directly; no separate
verification round was needed.

## Architectural Alternatives

### A. Comment The Existing Escape Hatches

Pros:

- Smallest diff.
- Documents the intent of each existing unchecked boundary.

Cons:

- Leaves the compiler unable to prove the most important concurrency facts.
- Normalizes unsafe escape hatches in a codebase that is still young enough to fix
  the structure.
- Conflicts with the user's explicit quality bar.

Failure modes:

- Future code copies the pattern and creates real shared mutable state crossing
  actors.
- Review has to reason from comments rather than compiler guarantees.

Rejected.

### B. Remove Unchecked Sendability And Add Deterministic Test Support

Pros:

- Lets Swift 6 prove sendability at current boundaries.
- Keeps the filesystem watcher off-main without unchecked conformance by using
  standard synchronization.
- Makes async tests wait on real events rather than sampling time.
- Preserves the current architecture and avoids unrelated refactors.

Cons:

- Requires touching several tests at once.
- Leaves some intentional sleeps where the behavior is timeout/absence based.

Failure modes:

- Test helpers become too abstract and hide behavior.
- Manual debounce gates drift from production behavior if overused outside debounce
  tests.

Selected.

### C. Larger Concurrency Rearchitecture

Pros:

- Could remove more unstructured task sites and shrink Store/ViewModel files.
- Might further simplify task ownership long term.

Cons:

- Larger blast radius than the audit items require.
- Risks mixing code quality cleanup with product architecture changes.
- Would require separate ADR/spec work for new owners.

Failure modes:

- The increment becomes too broad to review; doc drift and tests remain unfixed
  while architecture churn expands.

Rejected for this increment, but large-file and task-ownership simplification
remain valid future quality work.

## Selected Approach

Select Alternative B.

This is the simplest correct approach for the observed quality problems: remove
the unsafe escape hatches outright, make the remaining asynchronous ownership more
explicit, and replace broad polling with event-driven waits where the code already
has a real owner signal.

## Interfaces, Ownership, And Data Flow

- `MediaTileDetailReader` is a `Sendable` value wrapping `CatalogStore`.
- `LoadedTile` is a `Sendable` value carrying an immutable decoded `CGImage?` and
  a string.
- `CatalogFilesystemWatcher` stores mutable callback/stream state in
  `Synchronization.Mutex` instead of unchecked sendability. The FSEvents callback
  only creates value `FilesystemEvent`s and invokes a copied handler.
- `CatalogStore` gets an injected `filesystemEventSleep` closure for debounce
  tests, defaulting to `Task.sleep`. Production behavior remains unchanged.
- Store JSONL diagnostics from synchronous branches go through
  `recordDiagnostic(operation:phase:fields:)`, a single best-effort helper that
  captures only operation strings and bounded fields.
- `CatalogWindowViewModel.startEnrichment()` now starts the coordinator only after
  `store.start()` succeeds.
- Tests use `AsyncValueRecorder`, `ManualSleepGate`, and Observation-backed window
  state streams.

## Concurrency And Actor Ownership

- No production or test type uses `@unchecked Sendable`.
- Watcher mutable state is synchronized outside actors because FSEvents is a C
  callback API. The callback still delegates catalog decisions to `CatalogStore`;
  it does not touch SQLite or debounce state.
- Store remains the actor owner of filesystem-event debounce and rescan scheduling.
- ViewModel remains MainActor and consumes Observation-visible state on MainActor.
- Test helpers are actors when they own mutable waiter arrays; timeouts race those
  actor methods from outside instead of mutating actor state directly.

## Instrumentation And Performance

No new runtime diagnostic surface is required. The increment reduces diagnostic
task sprawl by centralizing Store's best-effort JSONL task creation, and it keeps
high-frequency UI telemetry unchanged in Logger/signposts.

Performance evidence is the compile/test gate and source review: no app behavior or
hot-path algorithm changes were introduced. Future performance work should still
use `script/logs.sh` and `script/profile.sh` as required by the process docs.

## Living Documentation And Comment Audit

Updated:

- `Otos/Services/FileMaterialization.swift`
- `docs/index.md`
- `docs/requirements.md`
- `docs/process/code-review.md`
- `docs/process/testing.md`
- `docs/adr/0002-catalog-persistence-and-filesystem-scan.md`
- `docs/specs/0004-library-catalog-browser.md`
- `docs/specs/0016-cloud-materialization-detection.md`
- `docs/specs/0022-metadata-and-thumbnail-enrichment.md`
- `docs/specs/0025-store-owned-query-catalog-and-identity-grid.md`
- this spec

Deleted:

- The superseded root planning document for the grid/catalog transition, because
  ADR 0010, Spec 0025, onboarding, and the research docs now own the current
  material.
- The duplicate root agent-instructions mirror, because `AGENTS.md` is the
  canonical entry point and root markdown is now guarded as an entry-point-only
  surface.

`docs/onboarding.md` was checked. Its Store, Projection, ViewModel, grid,
enrichment, and FileMaterialization descriptions already matched the current
architecture, so no onboarding edit was required.

## Code-Smell Review

- Large-file smell: still present in `CatalogStore.swift` and
  `CatalogStorePersistence.swift`; out of scope for this increment.
- Unsafe concurrency escape: addressed; source now has zero `@unchecked Sendable`.
- Unstructured task ownership: improved in Store diagnostics and enrichment startup;
  remaining long-running tasks still have explicit owners.
- Timing-heavy tests: improved in the highest-churn Store, filesystem-event,
  lifecycle, Projection, and ViewModel paths.
- Source-hygiene brittleness: still accepted as an architecture guardrail, but new
  checks focus on high-level invariants rather than exact task spelling where
  possible.

## Acceptance Criteria

- `rg '@unchecked Sendable' Otos OtosTests` returns no matches.
- Source hygiene fails if unchecked sendability returns to source.
- Source hygiene fails if root markdown includes non-entry docs other than
  `README.md` and `AGENTS.md`.
- Source hygiene fails if current source/docs resurrect obsolete materialization
  wording that says the helper is unused.
- Store, Projection, ViewModel, filesystem-event, and lifecycle tests use
  event-driven helpers for ordinary state observation.
- `script/requirements-authority-check.sh`, `script/lint.sh`, `script/test.sh`,
  and `script/verify.sh` pass.

## Verification

- Local checks: `script/requirements-authority-check.sh`, `script/lint.sh`,
  `script/test.sh`, `script/verify.sh`.
- Focused source checks: `rg '@unchecked Sendable' Otos OtosTests`,
  stale-document search, source-hygiene tests.
- Remote CI: required through the normal PR flow unless GitHub reports a billing,
  spending-limit, quota, or Actions-start blocker.
