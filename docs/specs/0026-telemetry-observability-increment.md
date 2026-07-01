# Spec 0026: Telemetry Observability Increment

## Classification

- Work type: Process/tooling
- Scope: test isolation for shared diagnostics and per-run unified-log capture

## Problem And Goal

Telemetry sessions need timestamped per-run log files and tests must not append to the
shared developer diagnostics JSONL aggregate.

## Selected Approach

- Disable `CatalogDiagnostics.shared` by default when `XCTestConfigurationFilePath` is
  set or `processName == "xctest"`.
- Add `script/capture-run.sh` for build, launch, and timestamped `log stream` capture
  under `build/Logs/`.
- Document Thread Performance Checker in `docs/process/performance.md`.
- Defer JSONL `sessionID` until capture ambiguity is proven.

## Verification

- `CatalogDiagnosticsTests.defaultSharedDiagnosticsIsDisabledWhileTestsRun`
- `script/verify.sh`
