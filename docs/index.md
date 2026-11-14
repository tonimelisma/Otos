# Otos Documentation

Documentation is organized around **current truth**, not increments. Each kind has
one MECE home (see `AGENTS.md` → Documentation). When docs conflict with code,
inspect the code before changing behavior, and fix the doc in the same PR as the
behavior change. Git history owns old implementation history.

## Authoritative current-state docs

| Document | Owns |
| --- | --- |
| [../AGENTS.md](../AGENTS.md) | How to work here: product non-negotiables, engineering rules, git/CI/PR workflow, documentation model, and Definition of Done. |
| [requirements.md](requirements.md) | The registry of implemented product/system behavior. Rows map to the source files and tests that implement/verify them. Current-state only. |
| [architecture.md](architecture.md) | The one-page code map: one-directional dataflow, actor ownership, and where to make a change. |
| [design/design-system.md](design/design-system.md) | The authoritative design rules for user-facing surfaces (`DES-*`). |

Per-screen design specifications:

- [design/import-bar.md](design/import-bar.md) — import status surface layout, states, and copy.

Design supporting documents:

- [design/hig-validation.md](design/hig-validation.md) — HIG and accessibility audit of the `DES-*` rules, with the measured contrast table and the re-test procedure.
- [design/mockups/](design/mockups/) — HTML visual references for the design system and the import bar. The markdown above is authoritative; where a mockup disagrees, the markdown wins.

## Architecture Decision Records

Each ADR owns one architectural decision and justifies what was built. Supersede or
rewrite an ADR when the decision changes; never append increment history.

| ADR | Owns |
| --- | --- |
| [0001](adr/0001-repository-foundation.md) | Repository and toolchain foundation. |
| [0002](adr/0002-catalog-persistence-and-filesystem-scan.md) | GRDB/SQLite catalog persistence, filesystem facts, idempotent scan reconciliation. |
| [0003](adr/0003-library-root-selection-and-access.md) | Unsandboxed folder selection, normalized path identity, overlap rules. |
| [0004](adr/0004-catalog-ui-ownership.md) | Permanent single-window Store/Projection/ViewModel/View ownership. |
| [0005](adr/0005-catalog-publication-and-availability.md) | Projection publication, explicit selection delivery, transient availability. |
| [0006](adr/0006-catalog-grid-rendering.md) | AppKit grid rendering, no-blank invariant, animation/zoom, model-owned selection, thumbnail-only hit area. |
| [0007](adr/0007-catalog-order-reuse.md) | Superseded ordering/materialization decision retained for its precomputed-sort-key evidence. |
| [0008](adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md) | Filesystem source of truth, single overlay lifecycle, path identity, no sidecars, cloud materialization policy. |
| [0009](adr/0009-enrichment-storage-and-staleness.md) | Enrichment storage, `(size, mtime)` staleness signature, eager full-library materialization, two-pool coordinator. |
| [0010](adr/0010-store-owned-query-catalog-and-identity-grid.md) | Store-owned indexed SQLite queries, identity-plus-generation grid publication, visible detail reads, clean reset. |
| [0011](adr/0011-catalog-query-descriptor-best-values-and-cadence.md) | Query descriptor, generated best values, sort/filter query ownership, two-tier publication cadence. |
| [0012](adr/0012-media-asset-clipboard-representation.md) | Media grid clipboard copy: original file URLs on the pasteboard, references only, reading no bytes. |
| [0013](adr/0013-removable-and-device-sources.md) | Removable volume and MTP camera source identity, metadata, All Media exclusion, detach/forget, device staging. |
| [0014](adr/0014-sidebar-selection-and-source-lifecycle.md) | Sidebar default/attach selection, All-Media visibility, and honest unmount-driven eject. |
| [0015](adr/0015-observability.md) | Unified logging + Instruments-only signposts; rejects JSONL/event/counter sinks. |
| [0016](adr/0016-view-modes-and-preview-decode.md) | Grid/loupe/compare view modes and full-size preview decode ownership. |
| [0017](adr/0017-media-operation-ownership.md) | Media operation ownership: coordinator, executor, and Store journal split. |
| [0018](adr/0018-xxh3-content-hash-overlay.md) | XXH3-128 content hash overlay, gated on byte locality. |
| [0019](adr/0019-import-plan-namespace-and-build-ownership.md) | Import plan namespace resolution by folder enumeration; off-actor build ownership. |
| [0020](adr/0020-production-data-locations-and-the-developer-smoke-seam.md) | Production data locations and the developer smoke-run seam. |
| [0021](adr/0021-concurrent-import-planning-and-destination-reservations.md) | Concurrent import planning, the cross-plan destination reservation ledger, and execution-scoped rebuild suppression. |
| [0022](adr/0022-recoverable-media-deletion.md) | Recoverable Move to Trash: system Trash only, catalog-proven members, no permanent deletion. |
| [0023](adr/0023-test-architecture.md) | Test architecture: an OtosKit framework, an unhosted `OtosTests` bundle, and an in-memory preference store. |
| [0024](adr/0024-import-source-readiness-gate.md) | Import source readiness gate: withholding the Ready offer until a source's live scan/enumeration proves itself, not just its plan build completing. Also: the single `makePresentation` writer every published presentation funnels through. |
| [0025](adr/0025-volume-aware-path-equality.md) | Volume-aware path equality, derived relative-path keys, and respelling-safe overlay identity. |
| [0026](adr/0026-settled-naming-and-card-erase.md) | Settled import naming facts and the typed, explicit card-erase boundary. |
| [0027](adr/0027-destination-free-space-is-measured-at-the-attempt.md) | Destination free space is measured only at the attempt: no precheck, no polling, a 5 GB per-entry floor with in-flight accounting, `ENOSPC` as backstop, and a floor stop as a resumable Cancel-shaped outcome. |
| [0028](adr/0028-grid-drag-out-representation.md) | Grid and filmstrip drag-out: original file URLs, whole selection from a selected tile, plain click on a selected tile commits on mouse-up. |
| [0032](adr/0032-owner-state-requests-and-intent-ordering.md) | Owner state changes only in synchronous code, a request is a revision counter nothing clears, an error is never a fact, intents travel in one ordered stream, and blocking work leaves the actor by a named mechanism. |
| [0033](adr/0033-time-is-never-a-stand-in-for-a-fact.md) | Time never stands in for a fact that can be known; every wait on time is tagged deadline, backoff, schedule, measurement, poll, or a cadence citing its measurement, and `script/time-guard.sh` checks it. |
| [0031](adr/0031-browser-place-restored-on-relaunch.md) | The browser place (query, view mode, selection, position) is saved once at quit and restored at launch, checked against the loaded catalog. |
| [0044](adr/0044-verification-builds-share-compile-results.md) | Verification builds share one compilation cache across worktrees through prefix mapping; tests take the checkout from `OTOS_SOURCE_ROOT`; gates run in one pass; `check.sh --only` is iteration feedback, not evidence. |
| [0046](adr/0046-immich-accounts-as-read-only-sources.md) | An Immich account is a read-only fixed-library source synced from its server stream, browsable offline from stored renderings, with root-kind capabilities and one original-locality owner. |

## Research

Dated research passes, POCs, and benchmarks with sources and conclusions.
Non-authoritative: they record what we learned, not current behavior.

- [research/media-grid-best-practices.md](research/media-grid-best-practices.md)
- [research/catalog-storage-and-query-models.md](research/catalog-storage-and-query-models.md)
- [research/toolbar-sort-filter-architecture.md](research/toolbar-sort-filter-architecture.md)
- [research/removable-volume-and-camera-sources.md](research/removable-volume-and-camera-sources.md)
- [research/2026-08-19-zero-byte-media-handling.md](research/2026-08-19-zero-byte-media-handling.md)
- [research/2026-08-19-source-file-disposition-prior-art.md](research/2026-08-19-source-file-disposition-prior-art.md)
- [research/2026-09-04-grid-day-header-pinning-and-scroll-edge-effect.md](research/2026-09-04-grid-day-header-pinning-and-scroll-edge-effect.md)
- [research/2026-10-05-parallel-checks-and-live-reattach.md](research/2026-10-05-parallel-checks-and-live-reattach.md)
- [research/2026-11-01-build-and-check-speed.md](research/2026-11-01-build-and-check-speed.md)
- [research/2026-11-07-immich-api.md](research/2026-11-07-immich-api.md)

## Plans and roadmap

- [plans/](plans/) — numbered work plans; completed plans are deleted. None is active.
- [product/roadmap.md](product/roadmap.md) — a non-authoritative idea pile that never
  guides work unless the user explicitly asks for roadmap input.
- [templates/adr-template.md](templates/adr-template.md) — the ADR format.

Code reviews and DoD reports live on the PR, never in the repo tree. There are no
per-increment specs.
