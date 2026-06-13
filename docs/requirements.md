# Otos Current Requirements

This is the authoritative registry for implemented Otos behavior and active
engineering process requirements. It is current-state documentation only.
Unimplemented product ideas, future plans, candidate requirements, and roadmap
items do not belong in this file.

Every non-micro behavior change, bug fix, feature, refactor, regression guard,
or workflow change must add or update precise requirement rows and map them to
verification evidence.

Types:

- `Functional`: user-visible or system behavior.
- `Non-functional`: performance, reliability, privacy, accessibility, or quality
  constraints.
- `Architecture`: ownership, boundaries, data lifecycle, persistence, or
  construction rules.
- `Process`: agent, review, documentation, or workflow behavior.
- `Tooling`: scripts, CI, local checks, or build tooling.
- `Regression`: a specific behavior preserved because a failure was observed or
  called out.

Statuses:

- `Current`: implemented current behavior.
- `Changed`: intentionally changed in the current increment.
- `Retired`: no longer a current requirement.

Evidence should name concrete commands, tests, logs, traces, source files, or
manual proof. Avoid vague evidence such as "checked manually" without the exact
step.

## Foundation And Workflow

| ID | Type | Requirement | Acceptance example | Status | Evidence |
| --- | --- | --- | --- | --- | --- |
| FND-001 | Architecture | The repository shall preserve a blank-slate architecture with no compatibility shims, legacy Otos Studio architecture, or effort-based compromises. | Given a PR changes architecture, the spec lists alternatives and any retired paths; the PR confirms no shim or legacy path was introduced. | Current | `AGENTS.md`, PR checklist, `script/dod-report.sh` |
| FND-002 | Process | Non-micro increments shall start from a decision-complete spec and required ADRs before implementation. | Given a feature touches persistence, media I/O, rendering, catalog, or reusable boundaries, the PR links a spec and any required ADR. | Current | `AGENTS.md`, `docs/templates/spec-template.md`, `docs/templates/adr-template.md` |
| FND-003 | Process | `docs/requirements.md` shall contain only implemented current behavior, active process requirements, changed requirements for the current increment, and retired current requirements. | Given a future product idea or unimplemented behavior is discussed, it is not added to this registry as a current requirement. | Changed | `AGENTS.md`, `docs/process/development-workflow.md`, `script/requirements-authority-check.sh` |
| FND-004 | Tooling | Remote CI shall provide a useful fast gate and shall not require unavailable Xcode 27 hosted runners. | Given CI runs on a PR, it performs checkout, YAML, text hygiene, script inventory, and macOS lint checks without selecting Xcode 27 or running Xcode build/test. | Current | `.github/workflows/ci.yml`, `script/ci-text-hygiene.sh` |
| FND-005 | Tooling | Xcode 27 build and test verification shall be supplied as local PR evidence until a real Xcode 27 runner exists. | Given a PR is ready, it includes local `script/verify.sh` output summary and Xcode version. | Current | PR checklist, `script/verify.sh` |
| FND-006 | Non-functional | Performance-sensitive work shall produce repo-tooling evidence for jank or responsiveness impact. | Given a PR changes MainActor, SwiftUI, rendering, media I/O, or concurrency-sensitive paths, it lists `script/logs.sh` or `script/profile.sh` artifact paths and summarizes worst spans or blockers. | Current | `docs/process/performance.md`, PR checklist |
| FND-007 | Process | Agents shall treat any user guidance that affects product direction, app behavior, architecture, workflow, quality, regression protection, evidence, or future direction as requirement candidates. | Given the user states a new constraint, correction, example, preference, or behavior expectation, the agent captures it as one or more requirement candidates instead of leaving it only in chat. | Changed | `AGENTS.md`, `docs/process/development-workflow.md` |
| FND-008 | Process | Agents shall write captured requirements back to the user in detail for verification before implementation relies on them. | Given the agent hears new or changed requirements, it presents an atomic list split by requirement type and asks for correction when meaning or scope is unclear. | Changed | `AGENTS.md`, `docs/templates/spec-template.md` |
| FND-009 | Process | Requirements shall be atomic, precise, and independently verifiable. | Given one sentence combines unrelated behaviors, constraints, or failure modes, the agent splits it into separate rows or candidate bullets with individual acceptance examples. | Changed | `AGENTS.md`, `docs/requirements.md` |
| FND-010 | Process | Future ideas and unimplemented product plans shall be stored only in non-authoritative planning or spec documents until implemented. | Given a roadmap item or idea has not landed, it may appear outside this registry, but it is not a requirement, commitment, or implementation guide. | Changed | `docs/index.md`, `docs/product/roadmap.md`, `script/requirements-authority-check.sh` |
| FND-011 | Process | Captured user guidance shall be stored in repository documentation during the increment that captures it. | Given the user provides guidance that affects product direction, app behavior, architecture, workflow, quality, regression protection, evidence, or future direction, the agent records it in the correct repository document: current implemented requirements in this registry, implementation decisions in specs or ADRs, and unimplemented planning guidance in non-authoritative planning docs. | Changed | `AGENTS.md`, `docs/process/development-workflow.md` |
| FND-012 | Process | Agents shall not use roadmap, planning, or idea documents to guide work unless the user explicitly asks to use them for the current task. | Given a planning document contains product direction, wild ideas, abandoned concepts, or candidate behavior, the agent ignores it unless the user names that document or asks for roadmap/planning input. | Changed | `AGENTS.md`, `docs/index.md`, `docs/product/roadmap.md` |
| FND-013 | Process | Every increment of work shall end with a Definition of Done report that includes push status. | Given an agent finishes an increment or hands it off for review, the final report includes DoD evidence and the pushed remote branch and commit, or the exact blocker preventing push. | Changed | `AGENTS.md`, `docs/process/development-workflow.md`, `script/dod-report.sh`, PR checklist |
| FND-014 | Architecture | Otos architecture shall prefer the simplest correct model, owner, schema, state flow, and UI that satisfy verified requirements. | Given a spec or ADR compares alternatives, it identifies the simplest correct option and selects a more complex option only when requirements, measurements, or explicit user direction justify it. | Changed | `AGENTS.md`, `docs/process/development-workflow.md` |
| FND-015 | Non-functional | Performance-oriented complexity shall come after correctness, simplicity, and clear ownership unless an explicit requirement or measurement proves the simple path is insufficient. | Given a proposal adds a cache, pool, worker queue, generalized abstraction, split schema, or pipeline for anticipated scale, the spec or ADR defers it unless current evidence or user direction requires it. | Changed | `AGENTS.md`, `docs/process/development-workflow.md` |
| FND-016 | Process | ADRs shall define a MECE decision scope and shall not decide adjacent future architecture through placeholders or broad wording. | Given an ADR is added or changed, it states what it owns, what it references without owning, and which related decisions require separate ADRs or specs. | Changed | `AGENTS.md`, `docs/process/development-workflow.md`, `docs/templates/adr-template.md` |
| FND-017 | Architecture | Otos UI implementation shall prefer SwiftUI. AppKit shall be used only when SwiftUI cannot provide the required capability or cannot meet verified responsiveness or performance requirements. | Given a spec or ADR proposes AppKit, it identifies the SwiftUI approach considered and the capability, responsiveness, or performance evidence that requires AppKit. | Changed | `AGENTS.md` |

## Media And Privacy

| ID | Type | Requirement | Acceptance example | Status | Evidence |
| --- | --- | --- | --- | --- | --- |
| MED-001 | Privacy | User originals shall remain read-only unless a future implemented requirement explicitly changes that rule. | Given a feature reads media roots, it does not delete, modify, rewrite, or move originals without an approved spec, ADR, and current requirement. | Current | `AGENTS.md`, PR checklist |
| MED-002 | Functional | The app shall not fabricate user-visible or domain facts. | Given a date, path, provider state, progress value, count, or capability is unknown, the UI/domain model keeps it unknown or explicitly qualified instead of inventing a placeholder fact. | Current | `AGENTS.md`, feature tests once behavior exists |
| MED-003 | Privacy | Logs shall not expose raw filenames, absolute paths, thumbnails, EXIF payloads, or user-authored metadata by default. | Given instrumentation is added, log payloads use opaque identifiers, categories, counts, durations, and privacy-safe outcomes. | Current | `Otos/Support/Instrumentation.swift`, PR checklist |

## Implemented Product Surface

| ID | Type | Requirement | Acceptance example | Status | Evidence |
| --- | --- | --- | --- | --- | --- |
| APP-001 | Functional | Otos shall not claim implemented library, catalog, browsing, curation, import, export, or editing behavior before those features land. | Given current behavior is documented or summarized, it describes the app shell and foundation only unless source code, tests, and evidence prove a product feature exists. | Changed | `Otos/ContentView.swift`, `docs/product/roadmap.md` |
