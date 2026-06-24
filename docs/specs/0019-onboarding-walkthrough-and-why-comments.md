# Spec: Onboarding Walkthrough And Architecture Why-Comments

## Classification

- Work type: Process/tooling (documentation)
- Current requirement IDs: FND-035, FND-046; adds FND-063
- ADRs: none

## Problem

The owner is newer to Swift and wants to understand not just *what* the code does
but *why* it is shaped the way it is — why there are actors, why tasks capture
`weak self`, why work is split across types, and in what order to read the code.
The existing file guides explain mechanics but assume the reader already has a map
of the whole system and reads them in the right order. There is no single document
that walks the codebase top to bottom and explains the design rationale, and several
key decisions (why an actor, why weak self) are not stated at the point a reader
first meets them.

## Scope

In scope:

- Add `docs/onboarding.md`: a logical-order walkthrough of the codebase that
  explains the one big idea, the one-directional data flow, the concurrency model
  (why two actors, why MainActor), each file in reading order, and two end-to-end
  narratives.
- Add focused *why* comments at the core decision points the walkthrough references:
  why `CatalogStore` is an actor, why `CatalogProjection` is a separate off-main
  actor, why `CatalogWindowViewModel` is `@MainActor` and captures `weak self`, why
  `ContentView` is passive, and why the scanner reads metadata only.

Out of scope:

- A Swift-language primer (the owner understands actors, `weak self`, and similar);
  the document explains why *Otos* uses them, not what they are.
- Any code behavior change.

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected.
- [x] Captured guidance restated as a requirement.
- [x] Ownership, side effects, and tests addressed (documentation only).
- [x] At least three alternatives compared.
- [x] Stale-document and code-comment audits defined.
- [x] Open questions answered or out of scope.

## Captured Requirements For User Verification

| ID | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| FND-063 | Process | An onboarding walkthrough (`docs/onboarding.md`) shall exist as living documentation, walking the codebase in logical reading order and explaining the rationale for its key design decisions; architecture-boundary files shall state the *why* of their core choices (actor isolation, task/`weak self` lifetimes, layer boundaries) where a reader first meets them. | Current | docs/onboarding.md, this spec, AGENTS.md |

## Architectural Alternatives

### Alternative A (selected): One walkthrough doc plus point-of-use why-comments

Pros: a newcomer reads the doc once for the whole map, then finds the local why at
each declaration; the durable rationale is centralized and rots slowly, while the
inline whys stay short and close to the code.

Cons: adds a document and several comments to keep current.

Failure mode: the walkthrough drifts from the code. Mitigated by the
living-documentation audit, which now covers `docs/onboarding.md`.

### Alternative B: Only inline comments, no walkthrough

Pros: rationale lives with the code.

Cons: gives no reading order or whole-system map; a newcomer still does not know
where to start.

### Alternative C: Only a walkthrough doc, no inline comments

Pros: one place to maintain.

Cons: the reader has to context-switch to the doc every time they meet `actor` or
`weak self` in the code.

## Selected Approach

Alternative A. `docs/onboarding.md` is the whole-system map and reading order;
focused why-comments answer the local question at the declaration a reader is
looking at. Both are living documentation.

## Retirement Proof

Nothing retired. `docs/index.md` previously listed onboarding docs as deferred; that
note is updated to point to the new document.

## Living Documentation And Comment Audit

- Added: `docs/onboarding.md`, this spec.
- Updated: `AGENTS.md` (onboarding doc named as living documentation), FND-063 in
  `docs/requirements.md`, `docs/index.md`, and why-comments in
  `CatalogStore`, `CatalogProjection`, `CatalogWindowViewModel`, `ContentView`, and
  `CatalogScanner`.

## Acceptance Criteria

- `docs/onboarding.md` walks the codebase in reading order and explains the why of
  the data flow, the two actors, the MainActor ViewModel, and `weak self`.
- The named architecture files state the why of their core decision at the
  declaration.
- `script/verify.sh` passes.

## Verification

- Local: `script/verify.sh` (lint, requirements-authority, build, tests — comments
  and docs only).
- Stale-document audit: index updated; deferred-docs note corrected.
