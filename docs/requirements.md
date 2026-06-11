# Otos Requirements

This is the requirements registry for current Otos behavior and process. Every
non-micro behavior change, bug fix, feature, or refactor must add or update
requirement rows and map them to verification evidence.

Statuses:

- `Current`: implemented current behavior.
- `Proposed`: accepted direction, not implemented yet.
- `Changed`: intentionally changed in the current increment.
- `Retired`: no longer a requirement.

Evidence should name concrete commands, tests, logs, traces, or manual proof.
Avoid vague evidence such as "checked manually" without the exact step.

## Foundation And Workflow

| ID | Requirement | Acceptance example | Status | Evidence |
| --- | --- | --- | --- | --- |
| FND-001 | The repository shall preserve a blank-slate architecture with no compatibility shims, legacy Otos Studio architecture, or effort-based compromises. | Given a PR changes architecture, the spec lists alternatives and any retired paths; the PR confirms no shim or legacy path was introduced. | Current | `AGENTS.md`, PR checklist, `script/dod-report.sh` |
| FND-002 | Non-micro increments shall start from a decision-complete spec and required ADRs before implementation. | Given a feature touches persistence, media I/O, rendering, catalog, or reusable boundaries, the PR links a spec and any required ADR. | Current | `docs/templates/spec-template.md`, `docs/templates/adr-template.md`, PR checklist |
| FND-003 | Requirements shall map observable behavior to acceptance examples and verification evidence. | Given behavior changes, this registry has an updated row with concrete evidence before the PR is ready. | Current | `docs/requirements.md`, PR checklist |
| FND-004 | Remote CI shall provide a useful fast gate and shall not require unavailable Xcode 27 hosted runners. | Given CI runs on a PR, it performs checkout, YAML, text hygiene, script inventory, and macOS lint checks without selecting Xcode 27 or running Xcode build/test. | Current | `.github/workflows/ci.yml`, `script/ci-text-hygiene.sh` |
| FND-005 | Xcode 27 build and test verification shall be supplied as local PR evidence until a real Xcode 27 runner exists. | Given a PR is ready, it includes local `script/verify.sh` output summary and Xcode version. | Current | PR checklist, `script/verify.sh` |
| FND-006 | Performance-sensitive work shall produce repo-tooling evidence for jank or responsiveness impact. | Given a PR changes MainActor, SwiftUI, rendering, media I/O, or concurrency-sensitive paths, it lists `script/logs.sh` or `script/profile.sh` artifact paths and summarizes worst spans or blockers. | Current | `docs/process/performance.md`, PR checklist |

## Media And Privacy

| ID | Requirement | Acceptance example | Status | Evidence |
| --- | --- | --- | --- | --- |
| MED-001 | User originals shall remain read-only unless a future spec explicitly changes that rule. | Given a feature reads media roots, it does not delete, modify, rewrite, or move originals without an approved spec and ADR. | Current | `AGENTS.md`, PR checklist |
| MED-002 | The app shall not fabricate user-visible or domain facts. | Given a date, path, provider state, progress value, count, or capability is unknown, the UI/domain model keeps it unknown or explicitly qualified instead of inventing a placeholder fact. | Current | `AGENTS.md`, feature tests once behavior exists |
| MED-003 | Logs shall not expose raw filenames, absolute paths, thumbnails, EXIF payloads, or user-authored metadata by default. | Given instrumentation is added, log payloads use opaque identifiers, categories, counts, durations, and privacy-safe outcomes. | Current | `Otos/Support/Instrumentation.swift`, PR checklist |

## Future Rows

Add feature rows here before or with the implementing PR. Prefer requirement IDs
that group naturally by area, for example `CAT-*` for catalog, `REN-*` for
rendering, `THM-*` for thumbnails, and `UI-*` for user-interface behavior.
