# Spec: Filesystem Source Of Truth, Overlay Lifecycle, And Code Review Process

## Classification

- Work type: Process/tooling (with foundational architecture documentation)
- Current requirement IDs: FND-001, FND-002, FND-003, FND-010, FND-012, FND-014,
  FND-015, FND-046, MED-001, MED-002; adds FND-053 through FND-058.
- Future idea or candidate links explicitly requested by the user: none.
- ADRs: `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`.

## Problem

Otos is layered on media the user keeps on disk, usually in cloud-synced folders.
The owner clarified the defining product contract: the filesystem is the single
source of truth, Otos is a subordinate overlay, and Otos never takes the user's
media hostage. The existing docs stated "originals are read-only" and a narrow
"filesystem is the source of truth" inside ADR 0002, but did not raise this to a
product-wide principle, did not define one lifecycle for all overlay, and did not
record how cloud dataless files constrain catalog and future media work.

Separately, the repository has heavy process scaffolding (specs, ADRs, requirements
registry, code-smell reporting) but no code-review process document. The owner
asked for a durable review approach and to add Rob Pike's 5 Rules of Programming
across the docs.

Current repo state verified by inspection: the catalog is `CatalogStore` (GRDB +
in-memory working set) to `CatalogProjection` (10 Hz off-MainActor projection) to
`CatalogWindowViewModel` (MainActor adapter) to passive SwiftUI views, with the
grid bridged to `NSCollectionView`. The scanner reads only metadata resource values
and no bytes. There is no thumbnail, metadata, or editing code, and no user-authored
overlay, so every stored value is currently rebuildable by re-observing the
filesystem.

## Scope

In scope:

- AGENTS.md non-negotiables for filesystem truth, no-hostage, opt-in mutation, and
  a single overlay lifecycle, plus the Application Support and cloud-materialization
  baseline.
- Rob Pike's 5 Rules as a canonical AGENTS.md section, referenced from the process
  docs.
- ADR 0008 recording the filesystem-truth contract, overlay lifecycle, path
  identity, no-sidecar rule, and cloud materialization policy.
- New `docs/process/code-review.md` with the review lens, rubric, severity model,
  and merge gate.
- Current architecture requirements in `docs/requirements.md`.
- Strengthened non-authoritative framing in `docs/product/roadmap.md`.
- Index registration and process-doc pointers to Pike's rules.

Out of scope:

- Implementing thumbnails, metadata, editing, or any move-detection convenience.
- Changing the catalog schema, scanner, or any runtime behavior.
- Choosing a color-management pipeline beyond relying on system frameworks.

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected.
- [x] Captured user guidance is restated as precise requirements for user
      verification.
- [x] Observable current requirements and acceptance examples are listed.
- [x] Future ideas and unimplemented requirement candidates are separated from
      `docs/requirements.md`.
- [x] Roadmap, planning, or idea documents are ignored unless explicitly requested.
- [x] Ownership, side effects, persistence, cancellation, errors, progress,
      privacy, instrumentation, and tests are addressed (no runtime code changes).
- [x] At least three alternatives are compared (in ADR 0008).
- [x] Refactor retirement proof is defined, if applicable (nothing retired).
- [x] A repository-wide stale-document audit is defined.
- [x] A code-comment accuracy audit is defined (no source comments contradicted).
- [x] Performance/jank evidence is defined, if applicable (none; docs only).
- [x] Open questions are answered or out of scope.

## Captured Requirements For User Verification

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| FND-053 | Architecture | The filesystem is the single source of truth; the catalog and all overlay are a subordinate, rebuildable projection that defers to the filesystem. | Current | docs/requirements.md, ADR 0008, AGENTS.md |
| FND-054 | Architecture | Otos never takes media hostage: no opaque vault, no writes into the user's media folders, no sidecars; the catalog can be exported instead. | Current | docs/requirements.md, ADR 0008, AGENTS.md |
| FND-055 | Architecture | Otos mutates user files only via explicit opt-in user actions; the default is that nothing on disk changes. | Current | docs/requirements.md, ADR 0008, AGENTS.md |
| FND-056 | Architecture | One overlay lifecycle: overlay is held while its item exists inside a tracked library root, purged in full only on proven deletion or explicit library-root removal, never on temporary absence; identity is the filesystem path with no durable IDs, fingerprints, or sidecars. | Current | docs/requirements.md, ADR 0008 |
| FND-057 | Non-functional | Catalog, thumbnail, and metadata work must not force-materialize dataless cloud files; operate on metadata and defer byte access to user-visible off-main work. (Materialization policy later revised by spec 0021: deliberate, non-blocking, bounded background materialization is permitted; see ADR 0008.) | Current | docs/requirements.md, ADR 0008, AGENTS.md |
| FND-058 | Process | Changes are reviewed against `docs/process/code-review.md`, and Rob Pike's 5 Rules govern optimization decisions across the docs. | Current | docs/requirements.md, AGENTS.md, docs/process/code-review.md |

## Architectural Alternatives

The substantive identity and overlay alternatives (derived/authored split, durable
identifiers and fingerprints, sidecars, and treating any unobserved path as
deleted) are compared in full in ADR 0008. The alternatives below concern only how
to document the decisions.

### Alternative A: One ADR plus an AGENTS.md principle and a code-review doc

Pros:

- One decision record (ADR 0008) owns the contract; AGENTS.md states the
  non-negotiables; the process doc owns review.
- Matches the existing docs structure and MECE ADR rule.

Cons:

- Touches several docs in one increment.

Failure modes:

- A claim drifts between AGENTS.md and ADR 0008 if not kept consistent.

### Alternative B: Fold everything into ADR 0002

Pros:

- Fewer files.

Cons:

- ADR 0002 is scoped to persistence and scan; overlay lifecycle, no-hostage, and
  cloud materialization cross-cut future thumbnail, metadata, and edit work and
  would break its MECE scope.

Failure modes:

- ADR 0002 becomes a catch-all that decides future architecture.

### Alternative C: Only edit AGENTS.md, no ADR

Pros:

- Smallest change.

Cons:

- A filesystem-access and overlay-lifecycle decision that is expensive to reverse
  requires an ADR by the repo's own rules; principles in AGENTS.md lack the
  alternatives and reversal plan.

Failure modes:

- The reasoning is lost and the decision looks like an unexamined rule.

## Selected Approach

Alternative A. ADR 0008 owns the filesystem-truth contract, overlay lifecycle, path
identity, no-sidecar rule, and cloud materialization policy, referencing ADR 0002,
0003, and 0005. AGENTS.md states the matching non-negotiables and the canonical
Pike's-rules section. `docs/process/code-review.md` owns the review rubric. This
keeps each document MECE and consistent with the existing structure.

## Interfaces, Ownership, And Data Flow

No code, schema, type, or runtime behavior changes. The decisions constrain future
work: future thumbnail, metadata, and editing features inherit ADR 0008's single
overlay lifecycle and cloud materialization policy and keep pure path identity.

## Retirement Proof

Nothing is retired. ADR 0002 keeps the catalog schema and scan; MED-001 keeps the
read-only-originals rule. No code, schema, test, fixture, log, or accessibility
identifier is removed. ADR 0008 formalizes and extends existing statements.

## Living Documentation And Comment Audit

- Rewritten or extended: `AGENTS.md`, `docs/requirements.md`,
  `docs/product/roadmap.md`, `docs/index.md`, `docs/process/development-workflow.md`,
  `docs/process/performance.md`, `docs/process/code-smells.md`,
  `docs/process/testing.md`.
- Added: `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`,
  `docs/process/code-review.md`, this spec.
- Deleted: none.
- Code comments: the scanner and store file guides already describe filesystem-truth
  reconciliation; no source comment contradicts the formalized contract, so no code
  comment is edited in this increment.

## Instrumentation And Performance

None. This increment changes documentation only and adds no runtime path.

## Code-Smell Review

Documentation-duplication risk: Pike's rules are stated canonically in AGENTS.md and
referenced, not copied, from the process docs to respect the living-doc no-stale,
no-duplication rule. No Swift/macOS code smells apply because no code changes.

## Acceptance Criteria

- AGENTS.md states the filesystem-truth, no-hostage, opt-in-mutation, and overlay
  lifecycle non-negotiables and the canonical Pike's-rules section.
- ADR 0008 exists, is registered in `docs/index.md`, and is referenced by the
  Application Support and cloud baseline in AGENTS.md.
- `docs/process/code-review.md` exists and is registered in `docs/index.md`.
- `docs/requirements.md` contains FND-053 through FND-058 as Current rows with
  acceptance examples and evidence.
- `docs/product/roadmap.md` states it is a non-authoritative grab bag, never a
  decision basis, consulted only on an explicit "what else could we build", with
  implementation conditional on explicit user approval.

## Verification

- Local checks: `script/verify.sh` (requirements-authority, lint, build, test).
- Focused tests: existing `SourceHygieneTests.livingDocumentationHasNoKnownRetiredCurrentStateClaims`
  must still pass (no banned retired strings introduced; required AGENTS.md
  living-documentation strings preserved).
- Performance/log evidence: not applicable.
- Stale-document audit: completed across ADRs, specs, requirements, process docs,
  index, templates, and roadmap.
- Code-comment accuracy audit: completed; no source comments contradicted.
- CI expectations: fast gate (checkout, YAML, text hygiene, script inventory, lint)
  green; remote CI does not run Xcode 27 build/test.
