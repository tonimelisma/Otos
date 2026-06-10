# ADR 0001: Repository Foundation

## Status

Accepted

## Context

Otos is beginning as a fresh native macOS app. The foundation must prevent old
architecture, compatibility shims, and unverifiable work from becoming normal.

## Decision

Use a comprehensive foundation with AGENTS.md, spec and ADR templates, local
scripts, CI, a shared Xcode scheme, fixture provenance, and instrumentation
facade before product features are implemented.

## Alternatives Considered

### Minimal Documentation

Pros:

- Small.
- Fast to add.

Cons:

- Does not create runnable local checks.
- Does not make PR expectations enforceable.
- Does not establish instrumentation conventions in code.

### Complete Foundation

Pros:

- Creates a durable workflow.
- Makes local evidence and CI expectations explicit.
- Establishes fixture provenance and telemetry rules immediately.

Cons:

- Larger first diff.
- Requires keeping scripts aligned with Xcode beta.

## Consequences

Every future increment has a clear path: spec, ADR when needed, implementation,
instrumentation, local verification, and PR evidence. This raises the upfront
bar, but it prevents drift.

## Reversal Plan

If this foundation becomes too heavy, revise AGENTS.md and the scripts through a
new ADR. Do not silently bypass the workflow.
