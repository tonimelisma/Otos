# ADR 0011: Catalog Query Descriptor, Best Values, And Cadence

## Status

Accepted

## Context

Before this decision, the media browser showed a custom in-content header with a
duplicated library title and file count, ordered assets by one persisted path
sort key, and computed the tile's best capture date in Swift as `captureDate ??
createdAt ?? contentModifiedAt`. Enrichment stored a pre-resolved
`capture_date_unix`, while scan-time media kind classification was used only as
an eligibility gate and then discarded. `CatalogProjection` also reused the last
ordered-ID query for detail-only enrichment changes because enrichment could not
affect membership or order.

`docs/plans/0030-toolbar-sort-filter-query-surface-plan.md` was explicitly requested as the implementation blueprint for this
increment and records user-confirmed requirements: the titlebar is the only
library-name surface, no item count is shown, sort/filter live in native toolbar
and menu commands, best date/kind/format are Store-owned query facts, sort/filter
are session-only, direct user intents publish immediately, and background work
coalesces at roughly one second.

## MECE Decision Scope

This ADR owns:

- the `CatalogQueryDescriptor` as the single value that carries sidebar scope,
  media filter, and sort order through ViewModel, Projection, Store queries, and
  the AppKit grid reset policy
- the single-layer SQLite best-value model for best capture date, best media
  kind, and best format
- the current indexed query shapes for ordered IDs, unfiltered counts, and
  scoped filter options
- the two-tier publication cadence: immediate user-intent wakeups and roughly
  one-second background coalescing for scan, enrichment, thumbnail, and
  filesystem-event updates

This ADR references but does not own:

- filesystem source of truth, overlay lifecycle, and cloud materialization policy
  owned by ADR 0008
- enrichment storage of thumbnails and full metadata JSON owned by ADR 0009
- the existing single-window Store/Projection/ViewModel ownership split owned by
  ADR 0004 and ADR 0005
- the AppKit identity grid rendering boundary owned by ADR 0006
- clean destructive catalog reset and visible detail faulting owned by ADR 0010

Adjacent decisions requiring separate specs or ADRs:

- search
- metadata inspector/details UI
- media selection, activation, or editing
- anchor-item scroll preservation if offset preservation proves visually jumpy
- additional composite filter-by-sort indexes after measured query evidence

## Decision

Otos will model the media browser query as one `CatalogQueryDescriptor`:
sidebar scope, `MediaFilter`, and `MediaSortOrder`. ViewModel owns the
session-lifetime control state and forwards descriptor intents through one
newest-value lane as `CatalogQueryRequest` values with monotonic generations.
Projection owns descriptor normalization, publication
coalescing, empty-state meaning, filter-option publication, and final
`CatalogWindowState` construction. Store owns all ordered-ID, unfiltered-count,
and distinct filter-option SQL. SwiftUI and AppKit receive already-resolved state
and call owner intents; they do not query, sort, or filter themselves.

Projected states carry the generation of the query request used to build them.
The ViewModel applies projected query controls only when that generation exactly
matches the newest local intent generation. Removed-library fallback preserves
the same request generation because it resolves that intent; stale A -> B -> A
publications cannot roll controls back through descriptor equality.

SQLite stores scan facts (`kind`, `format`, and `name_sort_key`) and enrichment
facts (`ts_original_unix`, `ts_quicktime_creation_unix`, `ts_digitized_unix`,
`ts_gps_unix`, `enriched_kind`, and `enriched_format`). The current best values
are STORED generated columns:

```sql
best_capture_unix AS COALESCE(
    ts_original_unix,
    ts_quicktime_creation_unix,
    ts_digitized_unix,
    ts_gps_unix,
    created_at_unix,
    content_modified_at_unix
)
best_kind AS COALESCE(enriched_kind, kind)
best_format AS COALESCE(enriched_format, format)
```

The old `capture_date_unix` winner column and Swift best-date fallback chain are
retired. Enrichment persists role facts; SQLite owns the ranking. Tile display,
date sorting, and future current consumers read the same generated
`best_capture_unix` value.

Projection always asks Store for ordered IDs for the current descriptor on
publication. If enrichment changes best date, best kind, or best format, the next
background tick treats the resulting order or membership change as ordinary
truth. If the order is unchanged, `CatalogProjectionChangeSummary`
suppresses needless
SwiftUI/AppKit work as before.

Direct user query intents wake publication immediately. Background dirt from
Store notifications is coalesced by a roughly one-second cadence. Store scan
flush cadence, filesystem-event debounce, and enrichment apply flushing align to
that same background scale. Viewport priority hints remain immediate because
they affect scheduling, not UI publication.

Toolbar filter controls and View menu filter commands share
`CatalogFilterMenuContent`, so kind availability and partial-selection symbols
cannot drift between the two command surfaces while both still call the same
ViewModel descriptor intents.

## Alternatives Considered

### Alternative A: Swift-side best values and filter/sort

Pros:

- smallest schema change
- easy to prototype in Projection

Cons:

- duplicates best-date ranking between Swift callers and SQL sorting
- requires loading asset values instead of ordered IDs for query work
- reintroduces projection-side full-catalog sort/filter work

Failure modes:

- generated best-date policy disagrees with sort order
- metadata enrichment changes are missed or require ad hoc invalidation flags
- MainActor pressure returns through larger state assignments

### Alternative B: Store a pre-resolved winner for each best value

Pros:

- simple SELECT and ORDER BY columns
- easy to read in the model

Cons:

- stores policy results rather than facts
- ranking changes require file re-reads or fragile repairs unless every input
  fact is also stored
- repeats the `capture_date_unix` stale-policy problem for kind and format

Failure modes:

- future ranking changes cannot be rebuilt from catalog state
- Swift and SQL drift when a caller resolves a value differently

### Alternative C: Store facts and derive current best values in SQLite

Pros:

- one retained ranking policy for display and query order
- facts stay reusable when policy changes
- Store-owned indexed queries remain the only browser query path
- enrichment changing membership or order becomes normal catalog truth

Cons:

- schema is wider
- generated-column/index changes require destructive reset in the pre-user
  catalog
- direction-specific indexes are needed to avoid temp sorting for user-facing
  sort directions

Failure modes:

- missing a scan/enrichment fact in the upsert suppression key can hide a visible
  change or over-notify
- generated-column policy changes require a table rebuild
- sparse filters over very large libraries may require measured composite indexes

Alternative C is selected. It is the simplest correct architecture because it
keeps data facts in one persistence owner, keeps policy in one generated-column
definition, and keeps the UI passive.

## Consequences

- The catalog schema resets cleanly because this is a rebuildable pre-user
  projection.
- Tile date, date sort, and future date consumers cannot drift while they consume
  `best_capture_unix`.
- The toolbar and menu commands can update one descriptor state and share one
  intent path.
- Query request generations make stale-publication rejection independent of
  descriptor equality.
- Background enrichment may visibly reorder assets or change filter membership;
  this is correct behavior, not a special-case animation path.
- Query-plan tests must cover production SQL builders for the default and
  user-facing sort directions.
- If residual filter scans prove slow, the next step is measured composite
  filter-by-sort indexes, not a new projection cache.

## Retirement Proof

The implementing increment removes or proves unreachable:

- `capture_date_unix` and `idx_media_asset_capture_date`
- `MediaEnricher.resolveCaptureDate`
- `EnrichmentResult.captureDate`
- Swift `MediaAsset.bestCaptureDate` fallback computation
- `CatalogProjection` detail-only ordered-ID reuse and the file-guide claim that
  enrichment cannot affect membership or sort order
- `MediaGridView.header`, the file-count label, and the content-header layout
  slot
- `EnrichmentCoordinator.applyBatchSize`
- 100 ms default projection and scan flush cadence, and 500 ms filesystem-event
  debounce defaults
- requirement/docs wording that treats metadata sort/filter as unimplemented

## Living Documentation Impact

Update:

- `docs/requirements.md`
- `docs/index.md`
- ADRs 0002, 0005, 0009, and 0010
- specs 0004, 0007, 0009, 0011, 0012, 0014, 0022, and 0025 where they describe
  current cadence, ordering, enrichment hot columns, or future sort/filter status
- source file guides and focused comments in `CatalogModels`,
  `CatalogStorePersistence`, `CatalogStore`, `CatalogProjection`,
  `CatalogWindowViewModel`, `EnrichmentCoordinator`, `MediaEnricher`,
  `MediaGridView`, and `MediaAssetCollectionView`

Planning documents may remain non-authoritative as long as they do not claim
current behavior before code lands.

## Reversal Plan

If always-requery plus generated best values proves too slow, keep the descriptor
contract and add measured composite filter-by-sort indexes first. If that still
fails, introduce typed Store change classification so Projection can skip
ordered-ID queries only for changes proven unable to affect the active
descriptor. Reverting to Swift-side ranking or UI-side filtering would require a
new ADR because it would create a second source of query truth.
