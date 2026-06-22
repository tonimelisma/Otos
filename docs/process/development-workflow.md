# Development Workflow

Otos development is spec-driven and evidence-driven. The goal is not ceremony;
the goal is to prevent accidental architecture, hidden compatibility paths, and
unverified AI-generated code from becoming the app.

Keep the app as simple as possible. Simplicity is an architectural requirement:
choose the smallest correct model, owner, state flow, and UI that satisfy the
verified requirements. Performance work comes after correctness, simplicity, and
clear ownership. Do not add performance-oriented complexity for anticipated
scale until requirements, measurement, or explicit user direction prove the
simple path is insufficient.

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
- Restate captured user guidance as precise requirements for user verification.
- Link current requirement IDs in `docs/requirements.md` when implemented
  requirements already exist.
- Keep future ideas and unimplemented requirement candidates outside
  `docs/requirements.md`.
- Provide acceptance examples and verification evidence.
- Compare at least three architectural alternatives with pros, cons, and failure
  modes.
- Identify the simplest correct alternative and justify any extra complexity
  with verified requirements, measurements, or explicit user direction.
- For ADRs, include a MECE decision scope that names what the ADR owns, what it
  references without owning, and which adjacent decisions need separate ADRs or
  specs.
- Name ownership, side effects, persistence, cancellation, errors, progress,
  privacy, instrumentation, and tests.
- For refactors, list what is deleted, demoted, or replaced.
- For performance-sensitive work, name the log categories, signposted spans, and
  `script/profile.sh` templates that will be used.
- Resolve open questions or move them explicitly out of scope.

## Requirement Capture

User guidance is requirement input when it affects product direction, app
behavior, architecture, workflow, quality, regression protection, evidence, or
future direction. Agents must not leave that guidance only in conversation.

When guidance is heard:

- write the captured requirements back to the user in detail
- split bundled guidance into individual functional, non-functional, process,
  architecture, tooling, privacy, or regression items
- ask for correction when scope or meaning is ambiguous
- record captured current requirements in `docs/requirements.md`
- record unimplemented ideas, candidates, and planning guidance in
  non-authoritative planning docs, specs, or ADRs
- ignore roadmap, planning, and idea documents unless the user explicitly asks to
  use them for the current task
- include acceptance examples and evidence for current requirements

`docs/requirements.md` is not a backlog. It contains implemented current
behavior, active process requirements, current-increment changes, and retired
requirements only. Planning docs may contain wild ideas, abandoned options, and
concepts that are never intended for implementation.

## Living Documentation And Comments

Current ADRs, specs, requirements, process docs, indexes, templates, scripts,
and code comments describe the implementation that exists now. Git history owns
the implementation history. When a decision or mechanism changes, rewrite every
affected current claim or delete the document/comment if it no longer serves a
current purpose. Do not preserve stale names, old data flows, superseded
diagnostic policies, or obsolete backlinks as explanatory context.

Planning documents are the only exception: they may retain future ideas or
abandoned options when visibly labeled non-authoritative, but they must not claim
to describe current behavior or silently guide implementation.

Architecture and behavior increments must include two explicit audits:

- a repository-wide stale-document audit across ADRs, specs, requirements,
  process docs, indexes, templates, scripts, and backlinks
- a code-comment accuracy audit across affected architecture, concurrency,
  persistence, diagnostics, and AppKit boundaries

File guides and focused comments should let a Swift newcomer follow the complete
current data flow and understand why ownership and concurrency boundaries exist.
Comments should explain non-obvious mechanics, preservation rules, cancellation,
coalescing, and cache validation. They must not narrate syntax, compare against a
recently removed design, or read like an increment changelog.

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

Do not optimize by architecture preemption. A cache, pool, queue, protocol,
split schema, or generalized pipeline must either simplify the current design or
answer a verified need. Otherwise, defer it.

Keep verification close to the changed owner. Prefer narrow tests and targeted
log/profile evidence during development, then run the full local gate before
handoff.

## Definition Of Done

There is one Definition of Done for each increment. It covers the full path
through landing and cleanup; do not call an increment done while its PR is merely
open.

Verification is the agent's responsibility. User-operated manual testing is
never a DoD, merge, or cleanup prerequisite. The agent runs every available
automated, command-line, profiling, and runtime check itself. If the environment
cannot drive a useful interaction, the agent records that limitation, substitute
evidence, and residual risk, and moves the interaction to a non-blocking
after-DoD task without waiting for the user.

There is exactly one DoD report for an increment. Do not create, post, or send a
review handoff DoD, partial DoD, pre-merge DoD, or "ready for review" DoD. The
first DoD report the user receives must be the final DoD report, and the final
DoD report may only be sent after the entire DoD is complete or after a true
external blocker prevents completion.

The final DoD report must be included in the PR as a final comment and sent to
the user. It must use green and red status emoji for every question, with clear
textual descriptions rather than terse labels. It must answer what was done,
what planned work was not done, which design decisions were made, what
requirements/specs/ADRs/docs changed, what verification and CI proved, what code
smells remain, what media-originals and diagnostics review found, what risks remain, and which
merge/cleanup/final-clean-tree steps completed.

- Requirements, specs, ADRs, and docs are updated.
- The stale-document audit confirms that affected current docs, indexes,
  templates, scripts, and backlinks describe the landed design, and documents
  without a current purpose are deleted.
- The code-comment audit confirms that affected comments explain current
  mechanics and rationale without syntax narration, increment history, or
  retired behavior.
- Captured user guidance was restated to the user and stored in the correct
  current or planning document.
- Local `script/verify.sh` passes, or the exact blocker is recorded.
- Performance-sensitive changes include trace/log/diagnostic artifact paths.
- Code smells observed are listed, including `None observed` when true.
- Remote CI status is recorded, with quota waiver evidence only when GitHub
  explicitly reports an account billing, spending-limit, or exhausted Actions
  quota blocker that prevents jobs from starting.
- Unresolved risks and follow-ups are named.
- User-operated checks, when useful but unavailable to the agent, are listed
  only as non-blocking after-DoD tasks.
- `script/dod-report.sh` prints the final green/red DoD report only after the
  full increment is otherwise done.
- The increment branch and commits are pushed to the remote before handoff, or
  the exact push blocker is recorded in the DoD report.
- The PR is merged into `main`.
- Local `main` is updated to the merge commit.
- Post-merge verification is run when the increment changed build, test,
  workflow, dependency, project, or runtime behavior.
- The increment branch is deleted locally and remotely after merge.
- Any increment worktree is removed after merge.
- Stashes created for the increment are cleared after merge.
- Stale local branches, remote branches, and worktrees are reviewed and only
  removed when proven to belong to the completed increment and already merged or
  patch-equivalent to `main`.
- The final working tree is clean and ready for the next increment.
