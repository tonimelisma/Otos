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

The user-confirmed requirements behind this decision: the titlebar is the only
library-name surface, no item count is shown, sort/filter live in native toolbar
and menu commands, best date/kind/format are Store-owned query facts, sort/filter
are restored across launches with the browser place (ADR 0031), direct user intents
publish immediately, and background work
coalesces at roughly one second.

## MECE Decision Scope

This ADR owns:

- the `CatalogQueryDescriptor` as the single value that carries sidebar scope,
  media filter, and sort order through ViewModel, Projection, Store queries, and
  the AppKit grid reset policy
- the single-layer SQLite best-value model for best capture date, best media
  kind, and best format
- the current indexed query shapes for ordered IDs and unfiltered counts, and the
  filter's options
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
facts (`capture_instant_unix` — the library's capture instant, chosen by
`CaptureTimestamps.instantPrecedence` from the stored timestamp records — plus
`enriched_kind` and `enriched_format`). The current best values are generated
columns (`best_capture_local` virtual, the other two stored). `best_capture_local` is
the local capture time, defined in ADR 0039:

```sql
best_capture_local AS COALESCE(
    unixepoch(<capture_wall_compact as a UTC reading>),
    COALESCE(capture_instant_unix, created_at_unix, content_modified_at_unix)
        + assumed_utc_offset_seconds
)
best_kind AS COALESCE(enriched_kind, kind)
best_format AS COALESCE(enriched_format, format)
```

The old `capture_date_unix` winner column and Swift best-date fallback chain are
retired. Enrichment persists role facts; SQLite owns the ranking. Tile display,
date sorting, and future current consumers read the same generated
`best_capture_local` value.

Projection always asks Store for ordered IDs for the current descriptor on
publication. If enrichment changes best date, best kind, or best format, the next
background tick treats the resulting order or membership change as ordinary
truth. If the order is unchanged, `CatalogProjectionChangeSummary`
suppresses needless
SwiftUI/AppKit work as before.

Direct user query intents wake publication immediately. Background dirt from
Store notifications is coalesced by a roughly one-second cadence, which stands on
the measured MainActor cost of a reordering apply
(`docs/research/grid-reorder-cadence-and-appkit-diffable-apply.md`). The Store scan
flush keeps the same one-second scale on its own measurement; filesystem events and
enrichment results are coalesced by their owners' in-flight work instead of a timer
(`docs/research/2026-10-23-cadence-audit.md`). Viewport priority hints remain
immediate because they affect scheduling, not UI publication.

The toolbar and the View menu open the same filter popover and share the sort
menu's content, so native checked/mixed state and complete sort-order copy cannot
drift between the two command surfaces. Sort is
presented as six complete field-and-direction choices but still writes the same
`MediaSortOrder` value. The toolbar filter uses a native popover with Images, RAW,
and Videos parent toggles directly above their child file types. Partial child
selection gives the parent a mixed state; selecting every kind or clearing every
selection canonicalizes back to the empty, all-items descriptor.

The filter's options are the sidebar row's (owner order, 2026-11-13). The descriptor's
filter belongs to the sidebar row it was set in: choosing another row starts it
unfiltered, but the filter survives into that row's leaves and back (a map area or
stack, a person, a duplicate group) and into a restored place (APP-042,
`docs/design/people.md`), so a filter value and the rows that show it span the same
thing — the row: the popover always lists all three kinds, and under each the file
types present in the row's scope (`SidebarSelection.sidebarRow`, resolved by the same
`RootRegistry.scopePredicate` as every scoped read) plus every file type the filter
holds. A filter holds a file type under its kind (`FilterFileType`), which is what lets
it draw a row for a type the row no longer has. Options drawn from every available
source were rejected: a library then offered a town or a file type only a connected
card held, and choosing it matched nothing. Options drawn from the shown leaf were
rejected too: an area's options would shrink as the map moved, while the filter it keeps
is the row's. The View menu opens that same popover instead of duplicating the
hierarchy.

Every order the descriptor can ask for is answered by one index walked in its order. Each
sort field and direction has two: a global index led by the order's key, for a scope of
several roots, and a root-local one led by the root, for a scope of one. After the key each
holds the row's identity — root and path, the ties, ascending under either direction — and
every column a window read tests a row by: whether it is shown (`pending_trash_batch_unix_ms`,
`awaiting_presence`, `hidden_by_source`), whether it is a Live Photo's movie (`best_kind`,
`content_identifier`), which copy of identical files shows (`shown_copy_root_id`,
`has_copies`), and the filter's format and choice (`best_format`, `media_choice`, v76). So a
wide scope's walk under any filter but people and places tests each row from its index entry
and reads no table row; a person's or Unidentified Faces' test seeks the face index, and a
place's finds the row's coordinate in the location index and computes its cell there. The
order read carries a row's capture time only under a date order, whose index holds it as its
key: the day buckets and a keyed re-read use it there alone. A filter of chosen rows (Liked,
Disliked) seeks them through `idx_media_asset_chosen` and sorts the few it finds. A person's
order reads the person's own rows of `person_photo` (v78, ADR 0047), which carry those same
columns under the same names, and sorts them: their pages are in proportion to the person's
photos at every size, from five to the 17,000 of the most photographed. The measurements of
every order × scope × filter are in
`docs/research/2026-11-17-every-order-the-window-asks-for.md` and, for a person,
`docs/research/2026-11-17-a-persons-photos-in-order.md`.

Rejected: order indexes led by the kind, so a kind filter reads pages in proportion to the
rows it returns. Two kinds are two ranges SQLite can only merge by sorting, and an
unfiltered order reads every kind's range out of order, so each of the twelve would need a
kind-led twin — about 230 MB more index on the owner's catalog, written on every row — to
save the walk of an index the owner's All Media reads in 82 ms cold.

`best_format` tokens are MediaMetadata's file-type names (ADR 0039): HEIC, HEIF and
HIF are one `HEIF`, JPG/JPE one `JPEG`, TIF one `TIFF`, so every token is one filter
row and a file type's predicate is one `best_kind`/`best_format` pair.

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

Alternative C is selected. It is the simplest correct architecture because it
keeps data facts in one persistence owner, keeps policy in one generated-column
definition, and keeps the UI passive.

## Consequences

- Catalog schema advances are additive migrations. Future or unrecognized schemas
  refuse to open without erase so non-rebuildable overlay (import history) is not
  destroyed; see ADR 0010.
- Tile date, date sort, and future date consumers cannot drift while they consume
  `best_capture_local`.
- The toolbar and menu commands can update one descriptor state and share one
  intent path.
- Query request generations make stale-publication rejection independent of
  descriptor equality.
- Background enrichment may visibly reorder assets or change filter membership;
  this is correct behavior. Same-descriptor reorders render as animated moves
  per ADR 0006; they are ordinary truth adopted every background tick, not a
  special-case animation path outside the structural-apply policy.
- Query-plan tests cover the production SQL of every sort, scope kind and filter: a wide
  scope's order walks its index, sorts nothing and reads no table row
  (`CatalogStoreQueryPlanTests.everyOrderOfAWideScopeWalksItsIndexAndReadsNoTableRow`).
- A choice or a format written on a row moves its entry in all twelve order indexes (about
  50 KB more write-ahead log for a Like on the owner-shaped catalog).

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
- source file guides and focused comments in `CatalogModels`,
  `CatalogStorePersistence`, `CatalogStore`, `CatalogProjection`,
  `CatalogWindowViewModel`, `EnrichmentCoordinator`, `MediaEnricher`,
  `MediaGridView`, and `MediaGridBridgeView`

Planning documents may remain non-authoritative as long as they do not claim
current behavior before code lands.

## Reversal Plan

If always-requery plus generated best values proves too slow, keep the descriptor
contract and measure a filter's walk against an index led by what it filters first. If that still
fails, introduce typed Store change classification so Projection can skip
ordered-ID queries only for changes proven unable to affect the active
descriptor. Reverting to Swift-side ranking or UI-side filtering would require a
new ADR because it would create a second source of query truth.
