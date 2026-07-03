# Spec 0026: Telemetry Observability Increment

## Classification

- Work type: Process/tooling
- Scope: test isolation for shared diagnostics and per-run unified-log capture

## Problem And Goal

Telemetry sessions need timestamped per-run log files and tests must not append to the
shared developer diagnostics JSONL aggregate.

Current status: session-scoped diagnostics and `logs/` capture paths supersede the
file-location and XCTest-disable details below. See
`docs/specs/0034-session-scoped-diagnostics-and-log-hygiene.md`.

## Selected Approach

- `CatalogDiagnostics.shared` now writes session-scoped `-test` JSONL during tests
  instead of disabling shared diagnostics.
- `script/capture-run.sh` builds, launches, and captures timestamped `log stream`
  output under `logs/`.
- Document Thread Performance Checker in `docs/process/performance.md`.
- Defer JSONL `sessionID` until capture ambiguity is proven.

## Verification

- `CatalogDiagnosticsTests.defaultDiagnosticsWriteInTestSessions`
- `script/verify.sh`
