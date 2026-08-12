# Plan 0083 — Lint Hygiene, Properly

## Goal

Make `script/verify.sh` lint-clean without bandaids. The current run reports
`355 violations, 1 serious in 211 files` (`swiftlint 0.65.0`, `swiftformat 0.62.1`).
Only the 1 serious violation fails the build; the 354 warnings are informational
by design (`script/lint.sh` runs without `--strict`, AGENTS.md says size limits
are warnings). The goal is to fix every auto-fixable style violation, fix the
single serious error by wrapping the line, and explicitly accept or suppress the
intentional size warnings — not to split cohesive types or chase zero warnings.

Scope is **formatting + style only**. No behavior, no tests, no requirements
rows, no ADRs.

## Why now

355 warnings is noise that hides the one serious error. A reviewer cannot tell
whether a new PR introduced a real style regression or just inherited the
baseline. The increment that introduced the limit for `EnrichmentCoordinatorTests`
(`largeDatalessLibraryKeepsClaimAndMaterializationHandoffBounded` at `:366`,
171 chars) is now the only error, but it is lost in 354 warnings. Cleaning the
auto-fixable warnings restores the signal.

This is not a new class of work — `script/lint.sh` already runs as the first
step of `script/verify.sh`, and `AGENTS.md` Code Review explicitly watches for
"MainActor gravity" and "AppKit bridge sprawl" but not lint. The debt is
style drift from many increments without a periodic `swiftformat --fix` pass.

## Root cause

Three independent sources, conflated into one count:

1. **Auto-fixable style** (~320 of 355): `line_length` warning at 120, `opening_brace`,
   `closure_parameter_position`, `identifier_name` (`x`/`y`/`l`/`r`), `for_where`,
   `large_tuple`, `sorted_first_last`, etc. These are `swiftformat`/`swiftlint --fix`
   fixable and should never have accumulated — `brew bundle` installs both tools,
   but no increment ran the fix pass before commit.

2. **One serious error**: `line_length` error at 160
   (`EnrichmentCoordinatorTests.swift:366` — ` @Test(.enabled(if: …)) func large…`
   at 171 chars). Warning is 120, error is 160 (`/.swiftlint.yml: line_length:
   warning 120, error 160`). This single error is what `swiftlint` exits
   non-zero on; `script/lint.sh` is currently still green because it runs
   without `--strict` — warnings don't fail, but errors do. The `Found 355
   violations, 1 serious` line is the proof the error exists.

3. **Intentional size warnings** (~10-15): `file_length` warning 600
   (`CatalogStore.swift` 3980, `CatalogStorePersistence.swift` 1591,
   `CatalogWindowViewModel.swift` 792, `MediaGridBridge.swift` 1001,
   `CameraSourceMonitor.swift` 709, etc.) and `type_body_length` 400
   (`MediaOperationCoordinatorAdversarialTests` 882, `CameraSourceMonitor`
   class 414, `CatalogWindowViewModel` etc.) plus `function_body_length` 50
   and `cyclomatic_complexity` 10. These are intentionally cohesive types
   (Store, ViewModel, bridge) and must not be split to satisfy a warning.
   `AGENTS.md` says explicitly: "SwiftLint size limits (`file_length`,
   `type_body_length`) are warnings. Do not split a cohesive type only to
   satisfy them, and do not re-add hard `error:` thresholds. Cohesion sets
   boundaries."

A bandaid fix would be to raise `line_length` to 200, disable `type_body_length`
globally, or split `CatalogStore.swift` into 6 files. All three hide the signal
or create the wrong boundary. This plan forbids them.

## Inventory

From `swiftlint lint --config .swiftlint.yml` on `main` at `40afed8`:

| Rule | Severity | Count | Example site |
| --- | --- | --- | --- |
| `line_length` warning (120) | warning | ~180 | `CatalogStore.swift:864` 121 chars, `CatalogWindowViewModelSourceMonitoring.swift:104` 145 chars |
| `line_length` error (160) | **error** | **1** | `EnrichmentCoordinatorTests.swift:366` 171 chars |
| `opening_brace` | warning | ~35 | `CatalogStore.swift:1299:9`, `MediaGridBridge.swift:106:9` |
| `function_body_length` 50 | warning | ~15 | `CatalogStoreImportJournal.swift:87` 61 lines, `CatalogWindowViewModel.swift:197` 63 lines |
| `file_length` 600 | warning | ~6 | `CatalogStore.swift` 3980, `CatalogStorePersistence.swift` 1591 |
| `type_body_length` 400 | warning | ~3 | `MediaOperationCoordinatorAdversarialTests` 882 |
| `cyclomatic_complexity` 10 | warning | ~3 | `LibraryReorganizationRunner.swift:113` complexity 18 |
| `function_parameter_count` 5 | warning | ~5 | `CatalogStorePersistence.swift:744` 8 params |
| `large_tuple` 2 | warning | ~4 | `EnrichmentLeaseGateway.swift:53` |
| `identifier_name` 2-40 | warning | ~6 | `MediaGridBridge.swift:659 x`, `PanePresentation.swift:14 l,r` |
| `closure_parameter_position` | warning | ~4 | `CatalogWindowViewModel.swift:409` |
| `type_name` 3-40 | warning | 1 | `MediaOperationCoordinatorAdversarialTests` 42 chars (actually 38? — check, may be `MediaOperationCoordinatorAdversarialTests` at 38, borderline) |
| `superfluous_disable_command` | warning | 1 | `CatalogStore.swift:293` |
| others (`for_where`, `sorted_first_last`, `orphaned_doc_comment`) | warning | ~10 |  |

Total: 355 violations, 1 serious.

## Research grounding

- `/.swiftlint.yml:1-57` — `line_length: warning 120, error 160`, `file_length:
  warning 600` (no error), `type_body_length: warning 400` (no error). Config
  intentionally leaves size as warning — matches AGENTS.md.
- `script/lint.sh`:
  ```bash
  swiftformat --lint "$ROOT_DIR"
  swiftlint lint --config "$ROOT_DIR/.swiftlint.yml"  # no --strict
  ```
  Warnings are informational and must not fail the build; only errors fail.
  `script/verify.sh` calls `script/lint.sh` first — a failing lint blocks build/test.
- `script/verify.sh` on `main` currently prints `Found 355 violations, 1 serious`
  and exits 0 because only the serious error would fail, but `swiftlint` without
  `--strict` still exits 0 on warnings + 1 error? Actual behavior: `swiftlint
  lint` exits 0 unless `--strict` counts warnings as errors. Verify: the `1
  serious` is the line_length error at 160, but `script/lint.sh` still exits 0
  today — meaning the error is not failing the build either without `--strict`.
  Check locally before Stage 1; if the serious error does not fail the build,
  the plan must still fix it because it is a real style violation that
  `swiftlint --strict` or a future config would catch.
- `swiftformat` vs `swiftlint --fix`: `swiftformat` fixes `opening_brace`,
  `closure_parameter_position`, and some `line_length` via wrapping; `swiftlint
  --fix` fixes `for_where`, `sorted_first_last`, etc. Run both.

## Stages

Each stage is independently mergeable and leaves `script/verify.sh` green.

### Stage 1 — Fix the one serious error (no formatting churn)

Smallest correct step, proves the error is understood:

- Wrap `EnrichmentCoordinatorTests.swift:366`:
  ```swift
  @Test(.enabled(if: ProcessInfo.processInfo.environment["OTOS_SCALE_TEST"] == "1"))
  func largeDatalessLibraryKeepsClaimAndMaterializationHandoffBounded() async throws {
  ```
  Two lines, no behavior change, brings the longest line from 171 to ~90 chars
  (well under both 120 warning and 160 error).

Verification: `swiftlint lint` reports `355 → 354 violations, 0 serious`,
`script/verify.sh` still green.

### Stage 2 — Auto-fix style (~320 warnings, no hand edits)

Run the tools that already exist:

```bash
swiftformat .
swiftlint --fix --config .swiftlint.yml
```

This fixes `opening_brace`, `closure_parameter_position`, `for_where`,
`sorted_first_last`, `superfluous_disable_command`, and many `line_length`
warnings by wrapping. Review the diff — it should be whitespace/line-break only,
no logic changes. Commit as `style: swiftformat + swiftlint --fix`.

Expected delta: 354 → ~30 remaining (size/complexity/identifier/name that
require judgment). If the delta is not in that range, stop and investigate —
the tools may have been misconfigured.

Verification: `script/verify.sh` green, `git diff --stat` shows only style
files, no test failures.

### Stage 3 — Triage the remaining ~30 intentional warnings

Hand-triage the survivors, one rule at a time, with explicit acceptance:

| Rule | Disposition |
| --- | --- |
| `file_length` / `type_body_length` | **Accept as warning.** Do not split `CatalogStore`, `CatalogStorePersistence`, `CatalogWindowViewModel`, `MediaGridBridge`, `CameraSourceMonitor`. They are cohesive owners per `docs/architecture.md`. Leave the warning, do not add `// swiftlint:disable`. |
| `function_body_length` 50 | Fix only where the function is genuinely doing two jobs (extract a helper with a real name). Accept where the 50-line limit is arbitrary for a cohesive transaction (e.g., `CatalogStore` write paths). |
| `cyclomatic_complexity` 10 | Accept for `LibraryReorganizationRunner` (complexity 18 is the honest cost of the reorg state machine). Do not game it by splitting into `if` chains. |
| `function_parameter_count` 5 | Accept where the parameters are a coherent option bag (e.g., `MediaEnricher.live` 7 params). Consider an `Options` struct only if it removes current complexity — not to satisfy the count. |
| `identifier_name` (`x`/`y`/`l`/`r`) | Fix where the name is a real readability problem (`PanePresentation.swift:14` `l`/`r` → `left`/`right`). Keep `x`/`y` in geometry math where it is conventional. |
| `large_tuple` 2 | Fix by introducing a named struct only if the tuple is a real domain concept (e.g., `EnrichmentLeaseGateway` 3-tuple). Otherwise accept with comment. |
| `type_name` 3-40 | Accept `MediaOperationCoordinatorAdversarialTests` — 38 chars, descriptive, not a style problem. Do not rename to satisfy length. |
| `line_length` warning 120 survivors | Fix only where wrapping improves readability (long string interpolations, chained calls). Accept where the warning is on a long but readable line (e.g., a single `LocalizedStringResource` literal). |

For each accepted warning, document the reason in the PR description — not in
the code with `// swiftlint:disable`, unless the line would otherwise be
linted on every future edit and the acceptance is per-line intentional.

Verification: final `swiftlint lint` shows `0 serious` and warnings only for
size/complexity rules that AGENTS.md says are warnings. `script/verify.sh`
green. The diff for Stage 3 should be small — mostly renames and a few
extractions, not file splits.

## Non-goals and guards

- Do not split `CatalogStore.swift` (3980 lines) or `MediaOperationCoordinatorAdversarialTests` (882) to satisfy `file_length`/`type_body_length` warnings.
- Do not raise `line_length` warning from 120 to 200, and do not re-add `error:` to size rules.
- Do not run `swiftformat`/`swiftlint --fix` without reviewing the diff — a formatter bug that changes semantics must be caught.
- Do not fix warnings by adding `// swiftlint:disable` globally. Disables are per-line, justified, and rare.
- Do not touch `docs/requirements.md` or ADRs in this plan — that is plan 0082/0084.
