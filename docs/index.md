# Otos Documentation

This directory is the canonical documentation home for Otos. Root markdown is
limited to project entry points such as `README.md` and `AGENTS.md`.

When docs conflict with code, inspect the code before changing behavior. When
living docs conflict with each other, fix the documentation conflict in the same
increment as the behavior change.

All documents in the current-contract, ADR, spec, process, and template sections
are living current-state documentation. Rewrite affected claims and backlinks or
delete documents that no longer serve a current purpose. Git history owns old
implementation history.

## Current Authoritative Contracts

| Document | Owns | Update when |
| --- | --- | --- |
| [AGENTS.md](../AGENTS.md) | Agent workflow, non-negotiable principles, CI/PR rules, and Definition of Done. | Development workflow, gate policy, or repo-wide engineering rules change. |
| [requirements.md](requirements.md) | Implemented current requirements, active process requirements, current-increment changes, retired requirements, acceptance examples, and verification evidence. | Any non-micro behavior change, bug fix, feature, refactor, regression guard, or workflow change changes current requirements. |
| [process/development-workflow.md](process/development-workflow.md) | Work classification, Definition of Ready, worktree discipline, retirement proof, and landing expectations. | Increment workflow or PR readiness rules change. |
| [process/code-smells.md](process/code-smells.md) | Swift/macOS code-smell review guidance and DoD reporting expectations. | Review heuristics, Swift/macOS smell categories, or source references change. |
| [process/testing.md](process/testing.md) | AI-aware macOS testing strategy and verification layers. | Test strategy, test commands, or acceptance evidence expectations change. |
| [process/performance.md](process/performance.md) | Jank detection and performance evidence using the repo's OSLog/signpost and Instruments tooling. | Instrumentation categories, profile scripts, or performance budgets change. |
| [process/apple-docs.md](process/apple-docs.md) | Apple documentation grounding workflow and citation expectations. | The Apple documentation helper or citation policy changes. |
| [process/code-review.md](process/code-review.md) | Review lens, rubric, severity model, and merge gate for human and agent review. | Review criteria, severity model, or merge-gate policy changes. |
| [onboarding.md](onboarding.md) | A logical-order walkthrough of the codebase and the rationale for its key design decisions, for newcomers. | The architecture, data flow, or a core design decision changes. |

## Current Architecture Decisions

| ADR | Owns |
| --- | --- |
| [0001](adr/0001-repository-foundation.md) | Repository and toolchain foundation. |
| [0002](adr/0002-catalog-persistence-and-filesystem-scan.md) | GRDB/SQLite catalog persistence, in-memory retention, filesystem facts, and idempotent scan reconciliation. |
| [0003](adr/0003-library-root-selection-and-access.md) | Unsandboxed folder selection, normalized path identity, and overlap rules. |
| [0004](adr/0004-catalog-ui-ownership.md) | Permanent single-window Store/Projection/ViewModel/View ownership. |
| [0005](adr/0005-catalog-publication-and-availability.md) | Projection publication, explicit selection delivery, and transient availability. |
| [0006](adr/0006-catalog-grid-rendering.md) | Narrow AppKit collection rendering and structural/detail update mechanics. |
| [0007](adr/0007-catalog-order-reuse.md) | Sort every publication by precomputed key (no order cache) and share the full value map by copy-on-write. |
| [0008](adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md) | Filesystem source of truth, single overlay lifecycle, path identity, no sidecars, and the cloud materialization policy. |
| [0009](adr/0009-enrichment-storage-and-staleness.md) | Enrichment storage (JPEG thumbnails as files, metadata as an on-demand blob), the `(size, mtime)` staleness signature, eager full-library materialization, and the two-pool coordinator ownership. |

## Current Implementation Specs

| Spec | Owns |
| --- | --- |
| [0001](specs/0001-foundation.md) | Repository foundation implementation. |
| [0003](specs/0003-current-requirements-authority.md) | Current requirements and non-authoritative planning separation. |
| [0004](specs/0004-library-catalog-browser.md) | Saved libraries, persistence, automatic scans, and catalog browser surface. |
| [0005](specs/0005-catalog-state-diagnostics-cleanup.md) | Typed catalog identity, filesystem facts, and diagnostics foundation. |
| [0006](specs/0006-catalog-library-state-snapshot.md) | Projected library row shape and narrow view inputs. |
| [0007](specs/0007-catalog-window-model.md) | Single-window ViewModel and passive-view ownership. |
| [0008](specs/0008-package-descendant-scan-skip.md) | Package-descendant scan exclusion. |
| [0009](specs/0009-catalog-publication-and-availability.md) | Coalesced state publication and transient availability behavior. |
| [0010](specs/0010-appkit-jank-instrumentation.md) | Jank telemetry strategy and retained failure evidence. |
| [0011](specs/0011-placeholder-media-grid.md) | Placeholder collection grid behavior and rendering regression fix. |
| [0012](specs/0012-catalog-state-robustness.md) | Explicit intents, unknown availability, order validation, diagnostics split, and living documentation. |
| [0013](specs/0013-catalog-lifecycle-race-safety.md) | Serialized startup, replacement-safe transient scan ownership, and retained selection normalization. |
| [0014](specs/0014-catalog-task-and-mutation-ownership.md) | Weak ViewModel task lifetime, lossless serial mutations, and coalesced replacement selection. |
| [0015](specs/0015-filesystem-truth-and-review-process.md) | Filesystem-truth contract, overlay lifecycle, and the code-review process. |
| [0016](specs/0016-cloud-materialization-detection.md) | Cloud dataless-file detection facts, the media-metadata boundary, and the dead `FileMaterialization` detector. |
| [0017](specs/0017-catalog-publication-performance.md) | Cheap precomputed sort key and no-op-scan notification suppression, with before/after measurement. |
| [0018](specs/0018-catalog-order-cache-and-scoped-map-removal.md) | Remove the projection order cache and scoped value map now that the sort is cheap. |
| [0019](specs/0019-onboarding-walkthrough-and-why-comments.md) | Onboarding walkthrough and architecture why-comments. |
| [0020](specs/0020-scan-date-freshness-and-selective-sync-contract.md) | In-memory scan-date freshness, selective-sync contract correction, and the PR-review-comment increment process. |
| [0021](specs/0021-cloud-materialization-triggering-and-eviction-poc.md) | Cloud materialization triggering POC, the background-download contract change, the eviction constraint, and the retained non-blocking materialization helpers. |
| [0022](specs/0022-metadata-and-thumbnail-enrichment.md) | Background metadata and JPEG thumbnail enrichment: the data model, the cursorless two-pool coordinator, the viewport channel, and tile rendering. |
| [0023](specs/0023-filesystem-event-rescan-v1.md) | Running-app FSEvents: debounced per-root full rescans through the existing scan pipeline. |
| [0024](specs/0024-grid-flicker-and-thumbnail-jpeg.md) | Sidebar status, grid flicker, and static thumbnail bug fix: name-only sidebar rows, in-place same-identity tile reconfiguration, JPEG thumbnail storage, and projection/grid/thumbnail instrumentation. |

## Planning Documents

Planning documents can contain future ideas, wild concepts, abandoned options,
candidate requirements, and research notes. They are not proof that behavior
exists, they are not commitments, and they must not guide agent work unless the
user explicitly asks to use them for the current task.

| Document | Owns | Update when |
| --- | --- | --- |
| [product/roadmap.md](product/roadmap.md) | Non-authoritative idea and planning notes that may include concepts never meant to be implemented. | The user explicitly asks to record, revise, or use roadmap/planning material. |

## Templates

| Template | Purpose |
| --- | --- |
| [templates/spec-template.md](templates/spec-template.md) | Decision-complete implementation specs. |
| [templates/adr-template.md](templates/adr-template.md) | Architecture decision records. |

## Deferred Docs

Accessibility docs are deferred until the app has enough real product and code
structure for them to be useful. Do not create placeholders that merely restate
`AGENTS.md`. The onboarding walkthrough now lives at [onboarding.md](onboarding.md).
