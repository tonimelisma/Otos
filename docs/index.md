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

## Research

Dated research passes, POCs, and benchmarks with sources and conclusions.
Non-authoritative: they record what we learned, not current behavior.

- [research/media-grid-best-practices.md](research/media-grid-best-practices.md)
- [research/catalog-storage-and-query-models.md](research/catalog-storage-and-query-models.md)
- [research/toolbar-sort-filter-architecture.md](research/toolbar-sort-filter-architecture.md)
- [research/removable-volume-and-camera-sources.md](research/removable-volume-and-camera-sources.md)

## Plans and roadmap

- [plans/](plans/) — active, numbered work plans. **Deleted when the work is done.**
- [product/roadmap.md](product/roadmap.md) — a non-authoritative idea pile that never
  guides work unless the user explicitly asks for roadmap input.
- [templates/adr-template.md](templates/adr-template.md) — the ADR format.

Code reviews and DoD reports live on the PR, never in the repo tree. There are no
per-increment specs.
