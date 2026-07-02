# PLAN: Toolbar, Sort/Filter, Single-Layer Best Values, And 1 Hz Publication

Status: non-authoritative planning document. Placed at the project root by
explicit user request (root markdown is otherwise limited to entry points).
This plan is the implementation blueprint distilled from
`docs/research/toolbar-sort-filter-architecture.md`; per the spec-driven
workflow it feeds one new ADR and per-increment specs before code lands. It
never claims current behavior.

## 1. Goal

Replace the media browser's in-content header (duplicated library name plus
file count) with a native macOS toolbar carrying filter and sort controls,
backed end-to-end by Store-owned indexed SQLite queries — no layer patched,
no second source of truth. Alongside it, rebuild the "best value" facts as a
single-layer SQLite derivation and retune the app's coalescing from 10 Hz to
a two-tier immediate/1 Hz model.

## 2. Decisions Already Made (user-confirmed)

- No in-content header. The window title alone carries the library name; no
  item count anywhere; the grid gains the header's height.
- Filter kinds: Images, RAW, Videos. RAW is raw still images only; all
  videos stay together. Menu interleaves each kind with its formats
  (Images / JPEG / GIF / … / RAW / ARW / DNG / … / Videos / MP4 / MOV / …),
  showing only formats actually present in the current scope.
- Sort fields: best date (default, newest first), file name, file size.
- The tile's displayed date, the sort key, and any future date consumer are
  the same "best available date": best embedded metadata date, else
  filesystem creation date, else modification date.
- Best values are single-layer in SQLite: enrichment persists timestamp role
  facts as columns; the entire ranking (metadata priority plus filesystem
  fallback) is one generated-column expression. No pre-resolved winner is
  stored; no ranking policy lives in Swift.
- Sort and filter persist per session only; relaunch resets to defaults.
- User intents publish instantaneously; background-driven updates (scan,
  enrichment, thumbnails) coalesce at ~1 Hz app-wide. The enrichment
  apply-batch size cap is deleted; time is the only batching parameter.
- Enrichment landing may change sort position and filter membership; the
  pipeline treats this as ordinary correct behavior (see evidence below).
- The raw-stills kind is labeled "RAW" in the UI.
- All four background-coalescing knobs (projection tick, scan persist
  cadence, filesystem-event debounce, enrichment flush) are a flat 1.0 s.
- Background reorders preserve pixel scroll offset; anchor-item pinning is
  deferred until real enrichment runs prove it necessary. Descriptor changes
  (user intents) still reset scroll to top.

## 3. Evidence Base

Repo inspection (see the research note for file-level detail):

- The grid pipeline already has the right seams: View → ViewModel intent
  streams → `CatalogProjection` (coalesced publication, order requery on
  structural change) → Store-owned SQL → ordered IDs → identity grid.
- `content_type_identifier` (UTI) is a persisted scan fact;
  `MediaEligibility` computes the image/movie UTType verdict at scan and
  discards it. Enrichment persists MediaMetadata's `family`/`file_extension`
  into `asset_metadata`, currently consumed by nothing.
- The tile already renders `bestCaptureDate` (Swift `??` chain); the grid's
  structural applies are non-animated, gate-serialized, offset-preserving.

Local library evidence (OneDrive, 2026-07-01, recorded in the research note):

- Non-iOS camera files (Sony HEIF/ARW pairs): filesystem birthtime and mtime
  equal the true capture instant exactly. The filesystem fallback is
  excellent for these.
- `_iOS` camera-upload files (1,271 in one month): filesystem dates are
  upload artifacts, wrong by hours-to-days; most are dataless placeholders;
  a materialized sample's EXIF matches the true capture instant. So date
  sort over this library **will** re-order visibly as enrichment lands, and
  a large fraction of real media needs enrichment before its date is right.
- Filename timestamp conventions differ per source (Sony local, iOS UTC):
  filenames are not date facts and are never parsed.

## 4. Target Architecture Overview

One value describes the grid query and flows through existing seams:

```swift
nonisolated struct CatalogQueryDescriptor: Hashable {
    var scope: SidebarSelection                 // existing
    var filter: MediaFilter                     // kinds + formats; empty = all
    var sort: MediaSortOrder                    // field + direction
}

nonisolated enum MediaKind: String { case image, raw, video }

nonisolated struct MediaFilter: Hashable {
    var kinds: Set<MediaKind>                   // whole-kind selections
    var formats: Set<MediaFormatToken>          // per-format narrowing
    var isActive: Bool { !kinds.isEmpty || !formats.isEmpty }
}

nonisolated enum MediaSortField { case bestDate, name, size }
```

Flow: toolbar/menu-bar → ViewModel intents (instant control state, session
lifetime) → newest-value query lane → Projection (descriptor is the query;
every publication requeries ordered IDs; ~1 s background tick, immediate
intent wake) → Store query builders (WHERE roots+kind+format, ORDER BY
sort+tiebreak, all on indexed generated columns) → ordered IDs → unchanged
identity grid.

## 5. Schema Changes (Store-owned, clean destructive reset per ADR 0010)

New scan-fact columns on `media_asset` (written by the scan upsert):

| Column | Type | Fact |
| --- | --- | --- |
| `kind` | TEXT | UTType classification: `raw` (conforms to `.rawImage`, checked first), `image`, `video` |
| `format` | TEXT | Normalized format token from the UTI's preferred extension (uppercase: `JPEG`, `HEIC`, `ARW`, `MP4`, …) |
| `name_sort_key` | TEXT | `MediaSortKey.naturalKey(name ?? last path component)` — numeric-aware file-name ordering (FND-061 mechanics) |

New enrichment-fact columns on `media_asset` (written by
`applyEnrichmentBatch`; hoisted because generated columns cannot cross
tables and these feed hot query paths — precedent: `capture_date_unix`):

| Column | Type | Fact |
| --- | --- | --- |
| `ts_original_unix` | DOUBLE | EXIF original instant (NULL when no usable UTC offset) |
| `ts_quicktime_creation_unix` | DOUBLE | QuickTime creation instant |
| `ts_digitized_unix` | DOUBLE | EXIF digitized instant |
| `ts_gps_unix` | DOUBLE | GPS instant |
| `enriched_kind` | TEXT | MediaMetadata family normalized through the same `MediaKind` vocabulary |
| `enriched_format` | TEXT | MediaMetadata extension normalized through the same token rules |

Generated best-value columns (STORED; the single retained definitions):

```sql
best_capture_unix GENERATED ALWAYS AS (COALESCE(
    ts_original_unix, ts_quicktime_creation_unix, ts_digitized_unix,
    ts_gps_unix, created_at_unix, content_modified_at_unix)) STORED
best_kind   GENERATED ALWAYS AS (COALESCE(enriched_kind, kind)) STORED
best_format GENERATED ALWAYS AS (COALESCE(enriched_format, format)) STORED
```

Indexes (start minimal per Pike; kind/format predicates run as residual
filters on index-ordered scans — no temp B-tree; add composite indexes only
with measured evidence):

- `(best_capture_unix, library_root_id, relative_path)` and root-local
  variant `(library_root_id, best_capture_unix, relative_path)`
- same pair for `name_sort_key` and for `byte_size`
- existing `sort_key` order and partial enrichment indexes unchanged
  (enrichment claim ordering still uses `sort_key`)

Retired: `capture_date_unix` column, `idx_media_asset_capture_date`.
`databaseNeedsCleanSchemaReset`'s required-column list is updated so old
databases reset cleanly (thumbnail purge path already exists).

Query builders in `CatalogStorePersistence` (all tested via query-plan
tests against the production builders, per SQF-001):

- `orderedAssetIDQuery(descriptor:rootIDs:)` — WHERE roots + optional
  `best_kind IN (…)` OR `best_format IN (…)`; ORDER BY the sort field's
  index expression, `ASC`/`DESC`, ending `library_root_id, relative_path`.
  NULL policy: date NULLs cannot occur while filesystem dates exist
  (MED-002: truly unknown stays NULL and sorts to the edge); size NULLs sort
  last via `byte_size IS NULL` prefix.
- `countAssetsQuery(descriptor:)` — unfiltered-scope count for empty-state
  disambiguation (existing two-step pattern).
- `distinctFilterableTypesQuery(rootIDs:)` — `SELECT DISTINCT best_kind,
  best_format` in scope; feeds the menu.

Filter WHERE semantics: `(best_kind IN selectedKinds) OR (best_format IN
selectedFormats)` — a whole-kind selection admits all its formats; format
selections narrow other kinds. Empty filter emits no predicate.

## 6. Writer Changes

Shared vocabulary (one Swift home, used by both writers so the COALESCE
layers are compatible):

- `MediaKind.classify(UTType) -> MediaKind?` — `.rawImage` before `.image`,
  `.movie` → `.video`. The scan's existing eligibility check and the new
  `kind` fact come from the same call (the verdict stops being discarded).
- `MediaFormatToken.normalize(...)` — uppercase canonical token from a UTI's
  preferred extension (scan) or MediaMetadata's extension (enrichment).

Scanner (`CatalogScanner` → `upsertScannedFile`):

- Writes `kind`, `format`, `name_sort_key` with the other facts.
- The upsert's change-suppression WHERE clause (FND-062) gains the new
  columns so a rescan that changes them notifies and an unchanged rescan
  stays silent. This is a correctness detail, not an option: missing it
  either breaks no-op suppression or hides visible changes.

Enricher (`MediaEnricher`, `EnrichmentResult`, `applyEnrichmentBatch`):

- `resolveCaptureDate` is deleted. The enricher maps the library's timestamp
  roles to the four instant columns as plain facts (a role without a usable
  UTC instant stays NULL; raw local-time components remain preserved in the
  metadata JSON) and emits normalized `enriched_kind`/`enriched_format`.
- `EnrichmentResult` carries the role instants and normalized tokens instead
  of a resolved `captureDate`; `writeEnrichmentOverlay` stamps the new
  columns. Validation (`enrichmentResultMatchesCurrentRow`) and the
  staleness signature are unchanged.
- The full metadata JSON keeps persisting everything, including roles not in
  the ranking; a future ranking change that needs one is a
  `json_extract` backfill migration plus a generated-column rebuild — no
  file re-reads.

Model changes: `MediaAsset` exposes `bestCaptureDate`, `bestKind`,
`bestFormat` as stored properties read from the generated columns (the
detail reader SELECTs them); the Swift `??` chain is deleted so display
cannot drift from query order. The tile's date text source is unchanged in
name, now database-derived.

## 7. Projection And Publication

Descriptor ownership:

- Projection holds the current `CatalogQueryDescriptor` (replacing bare
  `sidebarSelection`). Normalization generalizes: a removed selected library
  falls back to All Media while filter/sort survive; the retained-selection
  race rule (newer intent wins over an in-flight build's fallback) carries
  over verbatim.
- Every publication requeries ordered IDs for the descriptor (RE-A —
  always-requery). The detail-only cached-ID fast path and its "enrichment
  cannot affect order" assumption are retired; the published-state equality
  check remains the churn suppressor (unchanged order → no publication → no
  AppKit work). `orderQueryMs` diagnostics monitor the cost; the designed
  fallback if measurement demands it is typed change classification (RE-B in
  the research note), not a redesign.
- Empty-state policy gains `.noFilterMatches`, chosen when the unfiltered
  scope has assets but the filtered query returns none (existing two-step
  count pattern). The view renders it with a Clear Filters action.
- `CatalogWindowState` gains the resolved descriptor and the available
  filter options (distinct kinds/formats for the scope, refreshed on
  structural rebuilds) so menus render projected truth.

Two-tier cadence (one loop, one dirty flag, two wake sources):

- Background dirt (scan batches, enrichment applies, thumbnail promotions,
  filesystem events) marks dirty; a ~1 s timer tick picks it up
  (Projection cadence 100 ms → ~1 s).
- A user intent marks dirty and wakes the loop immediately (continuation
  gate or merged wake stream). Loop semantics are untouched: dirty clears
  before awaited reads, one build at a time, newer input stays dirty. The
  wake changes when the next pass starts, never what it does.
- Aligned knobs: Store scan persist cadence 100 ms → ~1 s;
  filesystem-event debounce 500 ms → ~1 s; `EnrichmentCoordinator`
  `applyBatchSize` deleted, replaced by a ~1 s flush timer (buffer bounded
  by one second of enrichment throughput; one flush → one transaction → one
  notification per second). Viewport priority hints stay immediate.
- FND-038 (10 Hz) becomes a two-tier requirement; tests use the existing
  injected-gate patterns (`ManualSleepGate`), not wall-clock sleeps.

Visual stability of 1 Hz reordering (mechanics already in the bridge):

- Applies stay non-animated and gate-serialized; unchanged tiles keep layer
  contents (content-key check); changed tiles repaint only their changed
  content.
- Scroll policy: descriptor change (user intent) resets to top; background
  reorders preserve scroll offset (ship first). Anchor-item preservation
  (record top-left visible ID pre-apply, re-scroll to it post-apply) is the
  designed follow-up if real enrichment runs feel jumpy. The apply gate's
  reset trigger extends from scope change to descriptor change.

## 8. ViewModel And UI

ViewModel:

- Session-lifetime descriptor control state (`@Observable`, no persistence);
  defaults: date newest first, no filter. Immediate checkmark echo, exactly
  like sidebar selection today.
- `setMediaFilter(_:)` / `setSortOrder(_:)` intents; the newest-value
  selection lane generalizes to a query lane carrying the whole descriptor
  (an obsolete filter click is as droppable as an obsolete sidebar click).
  Add/remove mutation and viewport lanes unchanged.

Toolbar (detail column, Liquid Glass conventions):

- Filter: `Menu` labeled `line.3.horizontal.decrease` (`.circle.fill` +
  tint while active) — sections per kind whose header row toggles the whole
  kind, format rows beneath with checkmarks, mixed indicator for partial
  kinds, "Show Everything" while active. Data-driven from published filter
  options.
- Sort: `Menu` labeled `arrow.up.arrow.down` — inline `Picker` for field,
  second inline `Picker` for direction (defaults: date ↓, name ↑, size ↓).
- Items grouped on shared glass; `ToolbarSpacer(.fixed)` separates them from
  future unrelated items; placements semantic (`.primaryAction`); help
  tooltips on both.
- Menu-bar parity: View ▸ Sort By / Filter submenus with shortcuts calling
  the same ViewModel intents (one action, one path; source-hygiene test).
- `MediaGridView.header` and the "N files" text are deleted;
  `.navigationTitle(title)` remains the only name surface.

## 9. Increment Plan (three PR-sized increments, each spec-first)

1. **Increment A — data foundation (no UI change).** New ADR (user-facing
   catalog query surface: descriptor ownership, single-layer best values,
   schema, index and cadence policy — the adjacent decision ADR 0010 named)
   plus spec. Schema v2 with clean reset; shared kind/format vocabulary;
   scanner and enricher writer changes; generated columns; `MediaAsset`
   best-value reads; new query builders + query-plan/behavior tests;
   `capture_date_unix` retirement. The app still renders path order — but
   the tile date is now database-derived.
2. **Increment B — cadence retune.** Two-tier publication loop, knob moves
   to ~1 s, `applyBatchSize` deletion, FND-038 requirement change,
   gate-based cadence tests. Small, independent, lands before the UI needs
   the intent wake.
3. **Increment C — descriptor and toolbar (user-visible).**
   `CatalogQueryDescriptor` through ViewModel/Projection/Store; RE-A
   always-requery and fast-path retirement; `noFilterMatches`; filter
   options publication; toolbar + menu-bar UI; header deletion; scroll-reset
   policy; end-to-end tests.

Each increment follows the repo's full workflow: decision-complete spec,
worktree, tests at the narrowest boundary, instrumentation evidence,
stale-doc audit (requirements rows FND-038/040/043/044/061/062, APP-001,
ADRs 0006/0009/0010 references, onboarding walkthrough), retirement proof,
`script/verify.sh`, PR, single final DoD report.

## 10. Retirement List (proof required in the implementing increments)

- `MediaGridView.header`, the "N files" count, and its layout `VStack` slot
- `capture_date_unix` column, `idx_media_asset_capture_date`, and every
  reference in queries, models, and tests
- `MediaEnricher.resolveCaptureDate` and `EnrichmentResult.captureDate`
- `MediaAsset.bestCaptureDate` computed `??` chain (becomes a stored
  column-backed property)
- `CatalogProjection` cached-ordered-ID reuse for `.assetsDetailChanged`,
  `needsOrderRequery` classification, and the "enrichment cannot affect
  membership or sort order" file-guide claim
- `EnrichmentCoordinator.applyBatchSize` and its size-triggered flush
- 100 ms projection cadence and scan persist cadence, 500 ms filesystem
  debounce as defaults
- FND-043's detail-only reuse wording; FND-038's 10 Hz wording (both become
  Changed rows with the new contract)

## 11. Risks And Measurements

- **Per-tick order query at scale (RE-A):** measured by `orderQueryMs`;
  fallback is typed change classification (RE-B), then composite
  `(best_kind, sort)` indexes — in that order, evidence first.
- **Structural apply cost on reorder:** `MediaGridStructuralApply` signpost;
  worst case one non-animated apply per second; anchor-item scroll
  preservation is the UX fallback.
- **Residual-filter scan cost:** kind/format predicates filter during
  index-ordered scans; if a sparse filter over a huge library proves slow,
  add the composite index for that (filter × sort) pair only.
- **Suppression-key regression:** the FND-062 upsert WHERE clause gains
  columns; a missed column silently breaks either notification or
  suppression — covered by scan-freshness tests both directions.
- **Ranking-change cost:** generated-column definitions are policy;
  changing them is a table-rebuild migration (pre-user: clean reset). The
  role columns and metadata JSON guarantee no file re-reads are ever needed.
- **Dataless-heavy libraries (evidence):** most `_iOS` files are dataless
  with wrong filesystem dates; date sort is initially upload-ordered for
  them and corrects as enrichment materializes and reads bytes. This is
  expected, truthful behavior; the equality check stops the churn once
  dates stabilize.

## 12. Acceptance Criteria (behavioral, end-to-end)

- Opening the app shows the toolbar, no in-content header, no count; grid
  is date-sorted newest first.
- Filtering to Videos/MP4 shows only matching assets; the filter icon shows
  active state; an empty result shows `noFilterMatches` with a working
  Clear Filters button; kinds/formats listed are exactly those present in
  the scope.
- Sort and filter react instantly to clicks; scan/enrichment progress
  repaints the grid at most about once per second.
- A file whose metadata date differs from its filesystem date moves to its
  correct position after enrichment, and the date on its tile equals the
  date implied by its grid position (same column).
- Sidebar scope changes and sort/filter changes reset scroll to top;
  background reorders do not reset scroll.
- Relaunching resets sort/filter to defaults.
- Menu-bar Sort By/Filter drive identical behavior to the toolbar.

## 13. Open Items

All product decisions are resolved (user-confirmed 2026-07-01: "RAW" label,
flat 1.0 s knobs, offset-first scroll policy — recorded in section 2). One
engineering verification remains:

1. Whether the one materialized iOS video whose Spotlight content date
   matched its filesystem date is a QuickTime-atom fact or a Spotlight
   fallback — verify with the MediaMetadata reader during Increment A.
