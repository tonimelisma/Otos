# Spec: <Title>

## Classification

- Work type: <Micro | Small behavior | Feature | Refactor | Bug fix | Research | Process/tooling>
- Requirement IDs:
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
- [ ] Observable requirements and acceptance examples are listed.
- [ ] Ownership, side effects, persistence, cancellation, errors, progress,
      privacy, instrumentation, and tests are addressed.
- [ ] At least two alternatives are compared.
- [ ] Refactor retirement proof is defined, if applicable.
- [ ] Performance/jank evidence is defined, if applicable.
- [ ] Open questions are answered or out of scope.

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
- CI expectations:
