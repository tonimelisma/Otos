# Spec: Current Requirements Authority

## Classification

- Work type: Process/tooling
- Current requirement IDs: `FND-003`, `FND-007`, `FND-008`, `FND-009`,
  `FND-010`, `FND-011`, `FND-012`, `FND-013`, `APP-001`
- Future idea or candidate links explicitly requested by the user: The user
  explicitly clarified that roadmap material is non-authoritative and must not
  guide work unless requested.
- ADRs: None

## Problem

The repo currently allows unimplemented product requirements to live beside
implemented process and behavior requirements in `docs/requirements.md` through a
`Proposed` status. That makes the registry look like a backlog, weakens the
difference between current truth and future thinking, and risks agents using
roadmap material as implementation guidance without the user asking for it.

Current repo state verified through inspection:

- `docs/requirements.md` contains implemented foundation rows and many
  unimplemented `Proposed` product rows.
- `docs/product/roadmap.md` describes planning material and previously referenced
  requirement IDs.
- `docs/index.md` lists the roadmap in the same living-contract table as current
  requirements.
- `AGENTS.md` has the spec-first workflow but does not yet require all user
  guidance to be restated and stored.
- `docs/templates/spec-template.md` does not yet include a dedicated captured
  requirements section.
- `script/verify.sh` does not yet guard against reintroducing proposed rows.

## Captured Requirements For User Verification

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| FND-003 | Process | `docs/requirements.md` must contain current implemented behavior, active process rules, current-increment changes, and retired requirements only. | Current | `docs/requirements.md` |
| FND-007 | Process | Any user guidance that affects product direction, app behavior, architecture, workflow, quality, regression protection, evidence, or future direction must be treated as requirement input. | Current | `AGENTS.md`, `docs/process/development-workflow.md` |
| FND-008 | Process | Agents must write captured requirements back to the user in detail for verification before implementation relies on them. | Current | `AGENTS.md`, `docs/templates/spec-template.md` |
| FND-009 | Process | Requirements must be atomic, precise, and independently verifiable. | Current | `AGENTS.md`, `docs/requirements.md` |
| FND-010 | Process | Future ideas and unimplemented product plans must remain outside the current requirements registry. | Current | `docs/requirements.md`, `docs/index.md` |
| FND-011 | Process | Captured user guidance must be stored in repository documentation during the increment that captures it. | Current | `AGENTS.md`, `docs/process/development-workflow.md` |
| FND-012 | Process | Roadmap, planning, and idea documents must not guide work unless the user explicitly asks to use them for the current task. | Current | `AGENTS.md`, `docs/index.md`, `docs/product/roadmap.md` |
| FND-013 | Process | Every increment must end with a Definition of Done report that includes push status. | Current | `AGENTS.md`, `docs/process/development-workflow.md`, `script/dod-report.sh` |
| APP-001 | Functional | Otos must not claim implemented product behavior before code, tests, and evidence prove it exists. | Current | `docs/requirements.md` |

## Scope

In scope:

- Remove all unimplemented requirements from `docs/requirements.md`.
- Remove the `Proposed` requirement status.
- Make `docs/requirements.md` current-state authority only.
- Add current process requirements for requirement capture, user verification,
  storage, precision, and roadmap isolation.
- Add current process requirements for ending each increment with DoD and push
  evidence.
- Mark roadmap and product planning docs as non-authoritative and opt-in only.
- Update `AGENTS.md`, process docs, README, spec template, and docs index to
  match the new authority model.
- Add a local/CI guard that rejects `Proposed` rows and roadmap requirement-ID
  blocks.

Out of scope:

- Implementing product features.
- Rewriting roadmap ideas into a new product plan.
- Treating roadmap content as current product direction.
- Creating ADRs; this is a process authority change, not a durable app
  architecture or persistence decision.

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected.
- [x] Captured user guidance is restated as precise requirements for user
      verification.
- [x] Observable current requirements and acceptance examples are listed.
- [x] Future ideas and unimplemented requirement candidates are separated from
      `docs/requirements.md`.
- [x] Roadmap, planning, or idea documents are ignored unless explicitly
      requested by the user for this task.
- [x] Ownership, side effects, persistence, cancellation, errors, progress,
      privacy, instrumentation, and tests are addressed.
- [x] At least three alternatives are compared.
- [x] Refactor retirement proof is defined.
- [x] Performance/jank evidence is not applicable.
- [x] Open questions are answered or out of scope.

## Architectural Alternatives

### Alternative A: Keep Proposed Rows In Requirements

Pros:

- Keeps current and future statements in one table.
- Avoids moving existing product rows.

Cons:

- Confuses current truth with backlog.
- Lets agents treat unimplemented ideas as authoritative.
- Does not satisfy the user's request to remove unimplemented requirements.

Failure modes:

- Roadmap rows become accidental implementation guidance.
- Requirements evidence is weak because planned behavior has no proof.

### Alternative B: Current Requirements Plus Non-Authoritative Planning

Pros:

- Makes `docs/requirements.md` authoritative for implemented/current behavior.
- Keeps future notes available without granting them authority.
- Supports precise user-guidance capture without turning ideas into commitments.
- Can be enforced with a small script.

Cons:

- Requires updating multiple docs whenever authority rules change.
- Requires agents to choose the correct storage location for each captured item.

Failure modes:

- Planning docs may still be over-read unless the opt-in rule is explicit.
- Current requirements can drift if future agents skip the guard script.

### Alternative C: Delete Roadmap And Planning Docs Entirely

Pros:

- Removes the chance of agents using planning docs accidentally.
- Simplifies documentation authority.

Cons:

- Loses useful notes when the user explicitly asks to work with ideas.
- Makes it harder to store future guidance without polluting current
  requirements.

Failure modes:

- Future ideas move back into chat only and are lost.
- Agents recreate planning docs inconsistently.

## Selected Approach

Use Alternative B: current requirements plus explicitly non-authoritative,
opt-in planning docs.

This is the right architecture because Otos needs a precise current truth source
and also needs somewhere to store user-provided future guidance that may never be
implemented. The separation avoids accidental backlog semantics while preserving
the user's ability to ask for roadmap or idea work later.

## Interfaces, Ownership, And Data Flow

- `docs/requirements.md` owns current implemented requirements, active process
  requirements, current-increment changes, retired requirements, acceptance
  examples, and evidence.
- `AGENTS.md` owns agent behavior: restate guidance, split requirements, ask for
  verification when needed, store guidance, and ignore planning docs unless the
  user explicitly asks to use them.
- `docs/process/development-workflow.md` mirrors the human-readable workflow.
- `docs/templates/spec-template.md` requires a captured-requirements section.
- `docs/index.md` separates current authoritative contracts from opt-in planning
  documents.
- `docs/product/roadmap.md` is demoted to non-authoritative idea notes.
- `script/requirements-authority-check.sh` enforces the no-`Proposed` registry
  rule and blocks roadmap requirement-ID sections.
- `script/dod-report.sh` reports upstream push status for increment closure.

No runtime app data flow changes. No persistence changes. No cancellation or
progress behavior changes. Privacy impact is limited to clearer requirements
around not inventing or exposing user media facts.

## Retirement Proof

Retire:

- `Proposed` as a requirement status.
- Unimplemented product rows in `docs/requirements.md`.
- "Future Rows" backlog language in `docs/requirements.md`.
- Roadmap `Requirement IDs:` blocks.
- Any docs language that makes roadmap material current authority or default
  implementation guidance.

Proof plan:

- Search for `Proposed` in `docs/requirements.md`.
- Search for `Requirement IDs:` in `docs/product/roadmap.md`.
- Run `script/requirements-authority-check.sh`.
- Run `script/ci-text-hygiene.sh self-test`.
- Run `script/verify.sh`, or record the exact blocker.

## Instrumentation And Performance

No runtime instrumentation is required. This increment changes docs and local/CI
guardrails only.

## Code-Smell Review

Relevant risks:

- Documentation drift between `AGENTS.md`, process docs, and templates.
- Ambiguous requirement grouping that hides multiple independent requirements.
- Planning docs still being treated as current authority.

Mitigation:

- Update all authority surfaces in the same increment.
- Add atomic requirement rows for each process rule.
- Add a guard script and call it from local verification and CI.

## Acceptance Criteria

- `docs/requirements.md` has no `Proposed` status and no unimplemented product
  rows.
- `docs/requirements.md` contains current process requirements for user-guidance
  capture, user verification, storage, atomicity, and planning isolation.
- `AGENTS.md` requires agents to restate captured requirements to the user and
  store captured guidance in the correct docs.
- `AGENTS.md` and process docs require every increment to end with DoD and push
  status.
- `docs/product/roadmap.md` states that it is non-authoritative, may include
  never-to-implement ideas, and must not guide work unless the user explicitly
  asks.
- `docs/index.md` separates current authoritative docs from opt-in planning docs.
- `script/requirements-authority-check.sh` fails if `Proposed` rows return to
  `docs/requirements.md`.
- `script/dod-report.sh` prints branch push status.

## Verification

- Local checks: `script/requirements-authority-check.sh`,
  `script/ci-text-hygiene.sh self-test`, `script/verify.sh`.
- Focused tests: Guard script detects forbidden `Proposed` rows and roadmap
  requirement-ID blocks.
- Performance/log evidence: Not applicable.
- CI expectations: Fast remote CI should run the requirement authority check
  through the text-hygiene job.
