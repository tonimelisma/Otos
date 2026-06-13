# Spec: Product Roadmap Documentation

## Supersession Note

This spec is historical. `docs/specs/0003-current-requirements-authority.md`
supersedes its requirement-authority model. Roadmap and idea documents are now
non-authoritative and must not guide work unless the user explicitly asks to use
them for the current task. `docs/requirements.md` no longer contains
unimplemented `Proposed` rows.

## Classification

- Work type: Process/tooling
- Requirement IDs: `FND-003`, `SRC-*`, `SCN-*`, `CAT-*`, `UI-*`, `REC-*`,
  `ENR-*`, `THM-*`, `VIEW-*`, `CUR-*`, `FIL-*`, `OPEN-*`, `IMP-*`, `PERF-*`
- ADRs: None

## Problem

Otos has foundation and workflow requirements, but no canonical product roadmap
for the first library, browsing, enrichment, and curation milestones. The repo
currently has `docs/requirements.md` and process docs, while `docs/index.md`
explicitly defers product docs until enough product structure exists.

This increment creates the first product roadmap and maps accepted product
behavior into Proposed requirement rows. It does not implement app behavior.

## Scope

In scope:

- Add `docs/product/roadmap.md`.
- Add Proposed product requirement rows to `docs/requirements.md`.
- Link the roadmap from `docs/index.md`.
- Preserve unrelated working-tree changes.

Out of scope:

- App code changes.
- Architecture ADRs for catalog storage, filesystem access, rendering, or
  thumbnails.
- Detailed specs for individual product slices.
- Extra product ideas not explicitly accepted.

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected.
- [x] Observable requirements and acceptance examples are listed.
- [x] Ownership, side effects, persistence, cancellation, errors, progress,
      privacy, instrumentation, and tests are addressed at product-doc level.
- [x] At least three alternatives are compared.
- [x] Refactor retirement proof is not applicable.
- [x] Performance/jank evidence is defined as future implementation evidence.
- [x] Open questions are answered or out of scope.

## Architectural Alternatives

### Alternative A: Roadmap Plus Registry

Pros:

- Provides a readable product plan and traceable requirement IDs.
- Fits the existing living-docs model.
- Lets implementation specs link to stable product requirements.

Cons:

- Requires keeping two docs synchronized.

Failure modes:

- Requirement rows drift from the roadmap if future increments update only one
  document.

### Alternative B: Roadmap Only

Pros:

- Keeps the initial product document simpler.
- Avoids a large requirements table update.

Cons:

- Leaves implementation specs without stable requirement IDs.
- Weakens the existing requirement-evidence workflow.

Failure modes:

- Future PRs invent requirement IDs ad hoc or skip requirement mapping.

### Alternative C: Registry Only

Pros:

- Keeps all requirements in one canonical table.
- Avoids a new product docs area.

Cons:

- Poor fit for roadmap priority, scope boundaries, and research grounding.
- Harder for humans to read as product strategy.

Failure modes:

- Product ordering and non-goals become implicit.

## Selected Approach

Use Alternative A: create a narrative roadmap plus Proposed requirement rows.
This is the right product architecture because Otos needs both a human roadmap
and traceable requirement IDs before implementation increments begin.

## Interfaces, Ownership, And Data Flow

This is a documentation-only increment. The public documentation interface is:

- `docs/product/roadmap.md` owns accepted product order, terms, non-goals, and
  research grounding.
- `docs/requirements.md` owns requirement IDs and acceptance examples.
- `docs/index.md` makes the roadmap discoverable.

No runtime data flow changes.

## Retirement Proof

Not applicable. This increment adds the first product roadmap and does not
replace code or behavior.

## Instrumentation And Performance

No runtime instrumentation is added in this increment. The roadmap requires
future implementation specs to instrument:

- Background filesystem scan and reconciliation.
- Coalesced Grid and film-strip updates.
- Metadata-driven reordering.
- Original-media loading and rendering for Image and Compare.

## Code-Smell Review

Relevant risks:

- Documentation drift between roadmap and requirement rows.
- Product facts stated more strongly than accepted decisions.
- Performance-sensitive requirements without future evidence hooks.

Mitigation:

- Keep roadmap and requirement rows in the same increment.
- Mark product rows as `Proposed`.
- Include future instrumentation requirements for scan, Grid, and render paths.

## Acceptance Criteria

- `docs/product/roadmap.md` exists and uses accepted view terms.
- Roadmap omits rejected product concepts and speculative backlog items.
- `docs/requirements.md` contains Proposed rows for each accepted product area.
- `docs/index.md` links the roadmap.
- Existing unrelated `AGENTS.md` changes are not modified.

## Verification

- Local checks: `script/verify.sh`.
- Focused tests: text checks for accepted/rejected roadmap terms.
- Performance/log evidence: Not applicable to docs-only work.
- CI expectations: Fast remote CI should pass after PR creation.
