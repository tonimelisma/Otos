# Development Workflow

Otos development is spec-driven and evidence-driven. The goal is not ceremony;
the goal is to prevent accidental architecture, hidden compatibility paths, and
unverified AI-generated code from becoming the app.

## Work Classification

Classify the increment before drafting or editing:

- `Micro`: mechanical edits with no behavior, architecture, or process change.
- `Small behavior`: one contained observable behavior change.
- `Feature`: new user-facing or system capability.
- `Refactor`: ownership, boundary, naming, or structure change.
- `Bug fix`: correction of an observed or reproducible failure.
- `Research`: investigation with written conclusions before implementation.
- `Process/tooling`: workflow, CI, scripts, or documentation guardrails.

Micro work can use a compact checklist. Everything else needs a spec and the
Definition of Ready below.

## Definition Of Ready

Before implementation starts:

- State the goal, change type, scope, and non-goals.
- Inspect the current repo state and summarize what was found.
- Link or add requirement IDs in `docs/requirements.md`.
- Provide acceptance examples and verification evidence.
- Compare at least two architectural alternatives with pros, cons, and failure
  modes.
- Name ownership, side effects, persistence, cancellation, errors, progress,
  privacy, instrumentation, and tests.
- For refactors, list what is deleted, demoted, or replaced.
- For performance-sensitive work, name the log categories, signposted spans, and
  `script/profile.sh` templates that will be used.
- Resolve open questions or move them explicitly out of scope.

## Worktrees And Branches

Use `codex/<description>` branches for agent-driven increments. Non-micro
increments should start in a dedicated git worktree when the work is new. If the
current task is already on an active increment branch, continue there and record
that fact in the PR.

Never discard work unless it is proven to belong to the current increment and is
already merged, patch-equivalent to `main`, or explicitly approved for removal.
Do not clean stale worktrees, branches, or stashes just because they are nearby.

## Architecture Retirement Proof

When an increment replaces an owner, path, schema, or concept, the old shape must
be deleted, demoted, or proven unreachable in the same increment. Retirement
proof should cover:

- files, type names, symbols, and construction paths
- tests, fixtures, and sample data
- docs, README examples, and comments
- log categories, messages, and signpost names
- accessibility identifiers when UI exists
- persistence tables, columns, migrations, and bootstrap paths

Do not leave compatibility bridges without a deletion target in the same spec.

## Implementation

Implement the selected design directly. If implementation reveals that the spec
is wrong, update the spec or ADR before continuing so review sees the real
decision trail.

Keep verification close to the changed owner. Prefer narrow tests and targeted
log/profile evidence during development, then run the full local gate before
handoff.

## Definition Of Done

Before PR handoff:

- Requirements, specs, ADRs, and docs are updated.
- Local `script/verify.sh` passes, or the exact blocker is recorded.
- Performance-sensitive changes include trace/log artifact paths.
- Code smells observed are listed, including `None observed` when true.
- Remote CI status is recorded, with quota waiver evidence only when GitHub
  explicitly reports exhausted Actions quota.
- Unresolved risks and follow-ups are named.
- `script/dod-report.sh` prints an actionable report for the branch.
