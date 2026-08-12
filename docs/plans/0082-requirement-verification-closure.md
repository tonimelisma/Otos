# Plan 0082 — Requirement Verification Closure

## Goal

Close the verification gap in `docs/requirements.md` without bandaids. Every
`unverified:` entry must be replaced by a real owner test that proves the exact
clause it names, or be narrowed to the precise remaining clause that genuinely
lacks machine-checked proof. The `manual:` escape hatch stays forbidden — the
gate already rejects it (`script/requirements-authority-check.sh:96-98`).

Scope is **tests + `Tested by` column updates only**. No production behavior
changes, so ADRs and implementation columns are untouched. Each batch updates the
requirement row in the same PR that adds its test (AGENTS.md: every behavior
change updates the affected rows in the same PR — here the "behavior" is the
proof).

## Why now

`docs/requirements.md` is the authoritative registry of implemented behavior
(AGENTS.md). Today it is not authoritative:

```
total rows:          96
verified (backtick path#symbol): 23 (24%)
unverified:                   73 (76%)
  ARC: 39/55 (71%)  APP: 18/23 (78%)  ENR: 14/15 (93%)  MED: 2/3 (67%)
  by debt kind: remaining clause 60, bounded clause 9, manual 4
```

`remaining clause not yet proven` (60 rows) is the bulk — a requirement cites one
or two happy-path tests but the row actually contains 4-6 `Given` clauses and
only the first is exercised. `bounded clause not yet proven` (9 rows) is honest
— the clause is known-hard (e.g., FSEvents `mustScanSubDirs` forcing a full
reconcile) and needs an adversarial harness, not a unit assert. `manual:` (4
rows: ARC-001, ARC-002, ARC-008, APP-008) was introduced as `unverified: manual
verification not machine-checked` and is rejected by the current gate as
`manual:` — the gate is correct; the rows need a real owner test or a narrowed
`unverified: <specific clause>` debt, not a blanket manual escape.

The prior increment (0080/0081 + `de9378a`) hardened the requirements gate
(locale-determinism, completeness) and removed the 400-char truncation that hid
this gap. The gap is now visible and must be closed incrementally, not by
flipping 73 cells to green in one diff.

## Root cause

Requirements were added as implemented with a `Tested by` entry that named the
primary happy-path test, plus `unverified: remaining/bounded clause not yet
proven` for the rest. That is honest debt, but it was never paid down. Because
`script/requirements-authority-check.sh` accepts `unverified:` as valid grammar
(`:107-114`) and CI has been billing-blocked (no remote gate runs), there was no
pressure to convert debt into proof. New rows copied the same pattern.

A bandaid fix would be to delete the `unverified:` suffix and leave the existing
single test as the whole proof, or to expand `ALLOWLIST`, or to re-allow
`manual:`. All three make the gate green while the behavior stays unproven.
This plan forbids them: a row is verified only when a test exists whose name
is cited as `` `path#symbol` `` and whose body actually asserts the clause
named in the `unverified:` reason.

## Inventory

Verified today (23): ARC-006,017,020,024,025,027,028,029,030,032,036,039,040,042,
047,052 · APP-004,005,007,012,016 · ENR-006 · MED-002.

Unverified (73) — grouped for reviewable batches:

| Batch | Prefix | Count | Example debt | What honest proof looks like |
| --- | --- | --- | --- | --- |
| A | ARC-001 … ARC-016 | 14 | ARC-001 SwiftUI vs AppKit, ARC-002 sandbox absent, ARC-008 typed IDs, ARC-009 scan idempotence | Owner boundary tests: compile-time or runtime asserts that the type/system is used, not a stringly check |
| B | ARC-017 … ARC-036 | 13 | ARC-018 catalog never writes into user media folders, ARC-033 overlay lifecycle | Store/filesystem contract tests with temp dirs, FSEvents injection, unreachable-root fixtures |
| C | ARC-037 … ARC-053 | 12 | ARC-048 import journal settlement, ARC-050 reorg planner, ARC-053 overlay reuse | Executor/journal adversarial tests with crash-matrix fixtures, already partially covered by `MediaImportExecutorTests` |
| D | APP-001 … APP-012 | 11 | APP-001 doc truth, APP-008 catalog-failure no-alert, APP-010 selection model | ViewModel + bridge tests that assert the absence of alert, selection model round-trips |
| E | APP-013 … APP-023 | 7 | APP-019 view-mode switcher, APP-020 loupe video, APP-022 strip scope | ViewModel view-mode policy tests, `PanePresentation`/`LoupeVideoState` tests |
| F | ENR/MED | 16 | ENR-008 provider breaker, ENR-009 25k handoff, MED-001/003 | Coordinator tests with fake materializer, scale-gated 25k test, media-eligibility tests |

`unverified: manual` (4): ARC-001, ARC-002, ARC-008, APP-008 — all need an
owner test, not a manual note. ARC-001/002 can be proven by project-file
assertions (`CODE_SIGN_ENTITLEMENTS` absent, `Info.plist`/`pbxproj`); ARC-008
by a compilation-boundary test that uses the typed IDs; APP-008 by asserting no
alert is presented on catalog failure and that the eject-failure alert is the
sole exception.

## Research grounding

- `script/requirements-authority-check.sh:89-152` — grammar: `manual:` rejected,
  `unverified:` requires non-empty reason, backtick proof must be `path#symbol`
  and the symbol must exist (`grep -Eq "func $test_name\("`).
- `script/verify.sh:7` runs `requirements-authority-check.sh check` first, so
  any row without `path#symbol` or `unverified:` fails locally.
- `docs/requirements.md` header (line 7-8): path cells must exist on disk —
  traceability only, not semantics.
- Prior art: plan 0080/0081 showed that whole-suite load can hide missing proof;
  tests must be load-independent (`withTestTimeout` + behavioral asserts, not
  wall-clock budgets).
- AGENTS.md: tests assert observable behavior or public owner boundaries, not
  implementation details; no source-file-as-text substring asserts.

## Stages

Each stage is independently mergeable, leaves `script/verify.sh` green, and
updates only the rows it proves.

### Stage 1 — ARC-001/002/008 + APP-008 (the `manual:` debt)

Smallest batch, establishes the pattern for rejecting `manual:`.

- Add owner tests:
  - `ARC-001`: assert SwiftUI is the default UI framework — e.g., a test that
    inspects `Otos.xcodeproj/project.pbxproj` for `CODE_SIGN_ENTITLEMENTS` absent
    and that `ContentView`/`OtosApp` are SwiftUI `Window` (not `WindowGroup`);
    or a compile-time test that the main window is a singleton SwiftUI `Window`.
    Do not assert via substring search of source text (forbidden).
  - `ARC-002`: assert unsandboxed — `project.pbxproj` has no `com.apple.security.app-sandbox`.
  - `ARC-008`: assert typed IDs at boundaries — a test that constructs a
    `LibraryRootPath`/`MediaAssetID` and passes it through a Store API, proving
    the type is required (not a bare string).
  - `APP-008`: assert catalog failures do not present a generic alert, while
    eject failure does — ViewModel test that drives a catalog failure and asserts
    no alert state, plus a fixture for busy-disk eject.
- Update the four rows' `Tested by` to cite the new `` `path#symbol` `` tests
  and remove the `unverified: manual` suffix. If a clause genuinely cannot be
  machine-checked (e.g., visual claim), narrow to
  `unverified: <specific visual clause> not machine-checked — requires snapshot` 
  rather than blanket `manual:`.

Verification: `requirements-authority-check.sh` clean with no `manual:`, new
tests green in isolation and under `xcodebuild -only-testing:` whole suite.

### Stage 2 — ARC-003 … ARC-016 (actor ownership + scan/idempotence)

Covers the Store/Projection/ViewModel ownership split and scan freshness. Many
rows already cite `CatalogStoreTests` but only for the happy path.

- For each row, read its `Requirement` + `Acceptance example` and list the
  `Given` clauses not yet proven. Add one test per missing clause, named
  `test<RequirementID><Clause>` so the `Tested by` cite is specific.
- Prefer existing harnesses: `CatalogStoreLifecycleRaceTests`,
  `ScanLeaseControllerTests`, `FilesystemEventFlagsTests`. Add a new
  `CatalogStoreOwnershipTests.swift` only if no existing file owns the question.
- Do not add a test that merely checks a file exists — assert the observable
  behavior (e.g., concurrent startup shares one load; stale scan suppresses
  missing-row deletion).

Batch size: ~14 rows, one PR. Reviewer checks each new test against the row's
acceptance example.

### Stage 3 — ARC-017 … ARC-036 (filesystem truth + overlay lifecycle)

Similar, focused on `AGENTS.md` non-negotiables: filesystem as truth,
overlay lifecycle, no writes into user media folders, dataless gating.

- Use temp-directory fixtures with real `FileManager` (not mocks) for
  reachability/unreachable, dataless status via `FileMaterialization` fakes,
  and FSEvents injection via `CatalogStoreFilesystemEventTestSupport`.
- For ARC-033 (overlay purged only on proven deletion), add the missing
  `available` vs `dataless` vs `unreachable` matrix.

### Stage 4 — ARC-037 … ARC-053 + ENR/MED (import/reorg/hash)

Largest behavioral surface. Much is already tested in
`MediaImportExecutorTests`/`ReorganizationPlannerTests` but not cited per clause.

- For each requirement, add the missing clause test or, where a test already
  exists, cite it precisely as `` `path#testSymbol` `` instead of leaving
  `unverified:`.
- For ENR-008 breaker (`providerUnavailable` → 60s suppression), add the
  second consecutive `ETIMEDOUT` case if missing; for ENR-009 ledger, add the
  in-window retry exhaustion case.

### Stage 5 — APP-001 … APP-023 (UI surface)

ViewModel + bridge tests. `APP-001` (doc truth) stays `unverified: bounded`
unless a doc-coverage test is added; that is acceptable. For the rest,
assert the `Given` clauses: selection ring, `⌘A` selects all, `⌘C` copies
file URLs, view-mode round-trip preserves selection, loupe video poster vs
player, strip scope.

## Verification

After each stage:

- `bash script/requirements-authority-check.sh check` clean (no new `manual:`,
  every cited `path#symbol` exists)
- `bash script/requirements-authority-check.sh self-test` clean
- `bash script/verify.sh` green (build + whole suite, not just filtered)
- Re-run inventory:
  ```bash
  grep -c "unverified:" docs/requirements.md
  grep -c "manual:" docs/requirements.md  # must be 0
  ```
  Count must drop by exactly the batch size; no row may be marked verified
  without a new or newly-cited test that asserts the named clause.

## Non-goals and guards

- Do not bulk-remove `unverified:` in one commit. Each batch is one PR with
  paired test + `Tested by` update.
- Do not re-allow `manual:` or grow `ALLOWLIST`. The gate stays at
  `ALLOWLIST_MAX_COUNT=0`.
- Do not add substring-source-text asserts (AGENTS.md forbids).
- Do not split a requirement row into two to avoid writing a test — split only
  when the row genuinely does two jobs (requires ADR).
