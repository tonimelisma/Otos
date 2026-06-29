# Spec: <Title>

## Classification

- Work type: <Micro | Small behavior | Feature | Refactor | Bug fix | Research | Process/tooling>
- Current requirement IDs:
- Future idea or candidate links explicitly requested by the user:
- ADRs:

## Problem

Describe the user-facing goal, why it matters, and the current repo state
verified through inspection.

## Scope

In scope:

- <item>

Out of scope:

- <item>

## Definition Of Ready

- [ ] Goal, scope, and non-goals are explicit.
- [ ] Current repo state was inspected.
- [ ] Captured user guidance is restated as precise requirements for user
      verification.
- [ ] Observable current requirements and acceptance examples are listed.
- [ ] Future ideas and unimplemented requirement candidates are separated from
      `docs/requirements.md`.
- [ ] Roadmap, planning, or idea documents are ignored unless explicitly
      requested by the user for this task.
- [ ] Ownership, side effects, persistence, cancellation, errors, progress,
      privacy, instrumentation, and tests are addressed.
- [ ] At least three alternatives are compared.
- [ ] Refactor retirement proof is defined, if applicable.
- [ ] A repository-wide stale-document audit is defined for affected ADRs,
      specs, requirements, process docs, onboarding walkthrough, indexes,
      templates, scripts, and backlinks.
- [ ] A code-comment accuracy audit is defined for affected architecture,
      concurrency, persistence, diagnostics, and AppKit boundaries.
- [ ] Performance/jank evidence is defined, if applicable.
- [ ] Open questions are answered or out of scope.

## Captured Requirements For User Verification

List every requirement heard from the user before implementation relies on it.
Split bundled guidance into precise individual items.

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| <label> | <Functional | Non-functional | Architecture | Process | Tooling | Privacy | Regression> | <requirement> | <Current | Candidate | Retired> | <docs/requirements.md, spec, ADR, or planning doc> |

## Architectural Alternatives

### Alternative A

Pros:

- <item>

Cons:

- <item>

Failure modes:

- <item>

### Alternative B

Pros:

- <item>

Cons:

- <item>

Failure modes:

- <item>

### Alternative C

Pros:

- <item>

Cons:

- <item>

Failure modes:

- <item>

## Selected Approach

State the selected approach and why it is the right architecture for the
product.

## Interfaces, Ownership, And Data Flow

Describe public types, storage, I/O, owner boundaries, actor isolation,
`Sendable` boundaries, privacy effects, and how user actions enter the system.

## Retirement Proof

If replacing existing structure, list what must be removed, demoted, or proven
unreachable across code, tests, fixtures, docs, logs, accessibility identifiers,
and persistence/schema paths.

## Living Documentation And Comment Audit

List every current ADR, spec, requirement, process document, onboarding section,
index, template, script, backlink, and code-comment boundary that the change
affects. State which items will be rewritten and which documents/comments will be
deleted because they no longer serve a current purpose. Planning documents may
remain non-authoritative, but must not claim to describe current implementation.

Describe the substantial file guides and focused comments needed so a Swift
newcomer can follow the landed architecture. Comments must explain current
mechanics and rationale, not syntax, increment history, or retired behavior.

## Instrumentation And Performance

List OSLog categories, signpost spans, safe counts, `script/logs.sh` checks,
`script/profile.sh` templates, budgets, and trace/log evidence needed.

## Code-Smell Review

List relevant Swift/macOS smell risks from `docs/process/code-smells.md` and how
the implementation will avoid or address them.

## Acceptance Criteria

- <item>

## Verification

- Local checks:
- Focused tests:
- Performance/log evidence, if applicable:
- Stale-document audit:
- Code-comment accuracy audit:
- CI expectations:
