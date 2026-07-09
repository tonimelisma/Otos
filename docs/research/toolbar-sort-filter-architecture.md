# Toolbar, Sort, And Filter Architecture Research

Status: non-authoritative research note.

Date: 2026-07-01

This document records platform research, captured user direction, and
architectural alternatives for replacing the media browser's in-content header
with a native toolbar carrying sort and filter controls. It is design input
for a future ADR/spec, not proof that behavior exists and not a commitment to
implement a specific option.

## Problem

The detail pane renders a custom header (`MediaGridView.header`): the library
title in large text plus a "N files" count. The title duplicates
`.navigationTitle` in the window titlebar; the count is unwanted. The header
is app-drawn chrome that the architecture standards discourage and it costs
grid height.

The replacement is a native toolbar with:

- filtering by media kind and granular format, presented as interleaved
  groups: Images with its formats beneath it, RAW likewise, Videos likewise —
  showing only formats actually present in the current scope
- sorting by best available date (default, newest first), file name, or size

## Captured Direction (Candidate Requirements)

Non-authoritative until implemented; recorded per FND-007/FND-011.

- Functional: the toolbar replaces the in-content header; the window title
  alone carries the library name; no item count is shown anywhere.
- Functional: filter kinds are Images, RAW, and Videos. RAW covers raw still
  images only; all videos stay in one kind. The menu interleaves each kind
  with its formats (Images / JPEG / GIF / … / RAW / DNG / … / Videos / MP4 /
  MOV / …) and lists only formats present in the current scope.
- Functional: sort fields are best available date (default, newest first),
  file name, and file size.
- Functional: the date shown on a tile, the date used for sorting, and the
  date used by any future date feature are the same "best available date":
  the best media-metadata capture date when enrichment has produced one,
  otherwise the filesystem creation date, otherwise the filesystem
  modification date (creation-before-mtime confirmed by the user).
- Functional: sort and filter persist for the session only; relaunching
  resets to defaults (date newest first, no filter).
- Architecture: the scan-time media-kind classification (UTType conformance)
  shall be persisted, not discarded after the eligibility gate.
- Architecture: where a fact exists in two layers (scan-time filesystem fact
  and enrichment-time media-metadata fact), the app shall use the enrichment
  value when available and fall back to the scan value, through one retained
  "best value" definition — not per-call-site coalescing.
- Architecture: the best-value system shall be single-layer, directly in
  SQLite. Enrichment persists timestamp role facts as columns; the entire
  ranking — metadata roles and filesystem fallback — is one generated-column
  expression. No pre-resolved "winner" value is stored, and no ranking policy
  lives in Swift.
- Architecture: enrichment landing shall be able to change sort position and
  filter membership (best date and best kind change as metadata arrives); the
  publication pipeline must handle this as ordinary, correct behavior.
- Non-functional: background-driven UI coalescing (metadata updates,
  thumbnail updates, scan batches) shall slow to roughly once per second
  app-wide; 10 Hz is unnecessarily fast for these updates. Direct user
  intents (sidebar, sort, filter) shall publish instantaneously — both
  behaviors are required, not a trade-off.
- Non-functional: batching should be simplified to time-based flushing where
  possible — the enrichment apply-batch size cap is replaced by the ~1 Hz
  flush alone.

## Current Repo State (Inspected)

- `MediaGridView` draws the custom header and also sets `.navigationTitle`.
  The grid consumes ordered IDs plus a detail-refresh generation and faults
  visible details by ID through the Store-backed reader.
- One fixed display order exists: the persisted `sort_key` (natural path key,
  FND-061) read via covering indexes with `INDEXED BY` and guarded by
  query-plan tests. Enrichment claim queries share that key.
- Intent flow: view → `CatalogWindowViewModel` intent streams →
  `CatalogProjection` (10 Hz coalesced publication, `needsOrderRequery` on
  structural/scope change) → Store-owned SQL. Detail-only changes reuse the
  cached ordered IDs on the stated assumption that enrichment cannot affect
  membership or order — an assumption date sorting invalidates.
- Type facts exist in two layers:
  - Scan-time: `content_type_identifier` (the UTI string from
    `NSURLContentTypeKey`) is persisted on `media_asset`.
    `MediaEligibility.isCatalogMedia` evaluates UTType conformance to
    `.image`/`.movie` during the scan but uses the verdict only as a pass/fail
    gate; the classification is discarded.
  - Enrichment-time: `MediaEnricher` maps the MediaMetadata library's
    `format.family` and file-extension into `asset_metadata.family` /
    `file_extension`. Persisted, currently consumed by nothing.
- Of everything MediaMetadata produces, only the resolved capture date and
  the thumbnail are consumed today (`capture_date_unix` and `thumbnail_path`
  are hoisted onto `media_asset` for hot reads). Family, extension, camera,
  lens, dimensions, duration, codec, and GPS are persisted (scalar columns
  plus JSON, per ADR 0009's "persist everything") but unused. This feature is
  their first consumer.
- Date semantics: `MediaAsset.bestCaptureDate = captureDate ?? createdAt ??
  contentModifiedAt`, computed in Swift, used by the tile. Any SQL ordering
  by date would need the same rule, creating a second implementation unless
  the definition is retained in one place.
- Coalescing knobs today: Projection cadence 100 ms, Store scan persist
  cadence 100 ms, filesystem-event debounce 500 ms, enrichment apply flush by
  batch size.
- ADR 0010 explicitly deferred "any future user-facing metadata filter/search
  feature" as an adjacent decision. This research is that decision's input;
  implementation requires a new ADR plus spec.

## Platform Research: HIG And Liquid Glass

From Apple's WWDC25 design sessions and current HIG (macOS 26 Liquid Glass,
carried forward with reduced transparency in macOS 27):

- Toolbars float on Liquid Glass above the content layer; items group
  automatically onto shared glass, and `ToolbarSpacer` splits groups. Glass
  never applies inside scrolling content.
- The window title belongs in the titlebar; declare toolbar items by semantic
  placement and let the system position them.
- Sort and filter are menu-bearing toolbar buttons: sort under
  `arrow.up.arrow.down`, filter under `line.3.horizontal.decrease`, with
  checkmark selection (`Menu` containing inline `Picker`s renders the native
  pull-down). Active filter state must be visible at a glance — filled symbol
  variant and/or tint while any filter is applied.
- Menu-bar parity: a View menu with Sort By / Filter submenus and shortcuts,
  calling the same intents as the toolbar (one action, one path).
- A filtered-to-empty grid explains itself and offers "Clear Filters"
  (`ContentUnavailableView`), distinct from no-media/unavailable states.
- The toolbar shape must not block a future trailing `.searchable` field;
  search architecture is not decided here.
- Naming precedent for raw stills: Apple Photos labels them "RAW" (badge and
  filter). "RAW" is the recommended kind label.

## Filter Menu Structure Alternatives

Criteria: state visibility at a glance, click count for common actions,
scalability to a dozen formats, and honesty about what is in the library.

### FM-A: Flat Interleaved Sections (recommended)

One menu; three sections headed Images, RAW, Videos; each kind's present
formats listed directly beneath its header. The kind header row is itself a
toggle for the whole kind; format rows narrow within it; a kind with a partial
format selection shows a mixed indicator. A "Show Everything" item appears
while any filter is active. Format rows are data-driven from a Store query of
distinct kinds/formats within the current scope.

- Pros: whole hierarchy visible in one open menu; matches the captured
  direction; one click for a kind, two for a single format.
- Cons: long menu in a very format-diverse library; mixed-state rendering
  needs care.
- Failure modes: without the data-driven distinct query the menu lists dead
  formats; with it, the query must be scoped or the menu lies.

### FM-B: Submenus Per Kind

Images ▸, RAW ▸, Videos ▸, each opening a format submenu.

- Pros: short top-level menu regardless of library diversity.
- Cons: active format selections hidden behind hover; more pointer travel;
  works against glanceable state.
- Failure modes: users cannot see why the grid is filtered without opening
  three submenus.

### FM-C: Segmented Kind Control Plus Format Menu

Always-visible segmented All/Images/RAW/Videos plus a separate format menu.

- Pros: one-click kind switching.
- Cons: two homes for one filter dimension; toolbar width; four segments is
  the practical ceiling and RAW already makes it four plus All.
- Failure modes: segment and menu state drift; overflow on narrow windows.

FM-A wins on state visibility and simplicity; FM-B is the fallback if real
libraries produce unmanageably long menus.

## Fact Layers And Best Values

The product rule: use the enrichment (media metadata) fact when it exists,
otherwise the scan (filesystem) fact. Applied to this feature:

- Best kind: enrichment-normalized kind, else scan-time UTType
  classification. Vocabulary is a closed Swift enum {image, raw, video}
  produced by one shared classification function used by both writers (scan
  classifies from UTType, with `.rawImage` conformance checked before
  `.image`; enrichment normalizes MediaMetadata's family through the same
  vocabulary).
- Best format: enrichment format token, else a scan-derived token from the
  UTI's preferred extension, normalized identically (e.g. JPEG, HEIC, DNG,
  MP4) so the two layers are COALESCE-compatible.
- Best date: the best metadata capture date, else filesystem creation date,
  else modification date (confirmed) — as a **single-layer ranking in
  SQLite**. MediaMetadata reports up to nine timestamp roles (EXIF original,
  digitized, TIFF, GPS, four QuickTime roles, RIFF); all remain preserved in
  the metadata JSON. The roles that participate in the current ranking
  (original, QuickTime creation, digitized, GPS — the order
  `MediaEnricher.resolveCaptureDate` implements today) become nullable
  columns on `media_asset`, written by enrichment as plain facts. The whole
  ranking is then one generated column:

  ```
  best_capture_unix GENERATED ALWAYS AS (COALESCE(
      ts_original_unix, ts_quicktime_creation_unix,
      ts_digitized_unix, ts_gps_unix,
      created_at_unix, content_modified_at_unix)) STORED
  ```

  `resolveCaptureDate` is deleted; no pre-resolved winner is stored anywhere.
  Swift retains only irreducible fact mapping: a timestamp without a usable
  UTC offset has `instant == nil` in the library result (raw local-time
  components stay in JSON), so its column is NULL and it never enters the
  ranking — MED-002, no fabricated UTC instants. This follows
  persist-facts/derive-policy: a stored winner is a policy result that goes
  stale if the ranking changes and can only be repaired by re-reading file
  bytes, whereas the generated column re-derives from persisted facts via a
  pure-SQL table rebuild. A future role added to the ranking can be
  backfilled from the preserved metadata JSON (`json_extract` migration), also
  without touching files.

### Where the "best value" is retained — alternatives

Criteria: single source of truth (sorting, filtering, and the tile must be
provably the same value), drift risk, indexability at the million-item
target, preservation of the scan/enrichment disjoint-writer invariant,
simplicity of ownership.

#### BV-A: Swift-Side Coalescing Per Consumer (status quo pattern)

`MediaAsset.bestCaptureDate` for display; equivalent `COALESCE` SQL repeated
inside each query builder.

- Pros: no schema change.
- Cons: two implementations of every best-value rule; the tile and the sort
  can silently disagree; each new consumer re-implements the rule.
- Failure modes: a future edit to one side but not the other produces a grid
  whose visible dates contradict its order — exactly the class of
  two-sources-of-truth bug the repo forbids.

#### BV-B: One Shared SQL Fragment

A single Swift constant emits the `COALESCE(...)` fragment for all builders,
plus expression indexes on it; Swift display still coalesces separately.

- Pros: SQL is DRY with itself; no schema change.
- Cons: still two implementations (SQL fragment vs Swift property); expression
  indexes must textually match the expression everywhere or SQLite ignores
  them.
- Failure modes: same drift class as BV-A, plus silent index misses when the
  fragment and index expression diverge.

#### BV-C: Stored Generated Columns (recommended)

Hoist the enrichment kind/format tokens onto `media_asset` as overlay columns
(the established hot-read pattern — `capture_date_unix` is already hoisted),
then define the best values as SQLite stored generated columns:

```
best_capture_unix  GENERATED ALWAYS AS (COALESCE(ts_original_unix,
                     ts_quicktime_creation_unix, ts_digitized_unix,
                     ts_gps_unix, created_at_unix,
                     content_modified_at_unix)) STORED
best_kind          GENERATED ALWAYS AS (COALESCE(enriched_kind, kind)) STORED
best_format        GENERATED ALWAYS AS (COALESCE(enriched_format, format)) STORED
```

All three are single-layer: every input is a persisted fact written by
exactly one writer (scan or enrichment), and every ranking is one SQL
expression. `capture_date_unix` (the stored pre-resolved winner) is retired
along with `MediaEnricher.resolveCaptureDate`.

Ordering and filtering index these columns directly. The detail reader
SELECTs them, so the tile displays the identical value the query sorted by.
The Swift `??` chains are deleted; `MediaAsset` exposes the read column.

- Pros: exactly one retained definition, in the schema; no writer maintains
  the derived value, so the scan/enrichment disjoint-writer invariant is
  untouched (generated columns have no writers); indexable like any column;
  sorting, filtering, and display are the same value by construction.
- Cons: schema change (pre-user destructive reset applies, ADR 0010); a
  definition change forces a reset+rescan (acceptable pre-user, and the rule
  is a product constant, not a tunable).
- Failure modes: generated columns cannot reference other tables — hence the
  hoisting requirement; forgetting it forces JOINs into every hot query.

#### BV-D: Writer-Maintained Derived Columns Or Triggers

Both writers (or SQLite triggers) keep `best_*` up to date.

- Pros: none over BV-C.
- Cons: reintroduces cross-writer coordination for shared columns, or hides
  write logic in trigger bodies outside the Store boundary.
- Failure modes: a writer that forgets the derived column ships stale best
  values; triggers are invisible to the "one persistence owner" rule.

BV-C is the only option with a single retained definition and zero writer
coordination. It answers "where is the best value retained": in the schema,
as the one place the rule exists, with every consumer — SQL and Swift —
reading rather than recomputing it.

## Sort Research

- Fields: best date (default, newest first), file name, file size.
- Date: `ORDER BY best_capture_unix` on the generated column, with covering
  indexes for global and root scopes; `DESC` needs no extra index (SQLite
  scans indexes backwards).
- Name: today's `sort_key` orders by library plus relative path (folder
  grouping), not file name. A persisted `name_sort_key` (natural key of
  `name`, same `MediaSortKey.naturalKey` mechanics, per FND-061) gives
  numeric-aware name ordering without per-row collation.
- Size: `byte_size` is a scan fact; index as needed.
- Deterministic tiebreak: every ordering ends `…, library_root_id,
  relative_path` so equal keys are stable across publications.
- NULL policy: SQLite sorts NULLs first ascending / last descending; with
  filesystem-date fallback, `best_capture_unix` is NULL only when no date
  fact exists at all (MED-002 keeps it unknown rather than fabricated).
- Index restraint per Pike: covering indexes for the sort orders only
  (global + root pairs, mirroring the existing order indexes); kind/format
  predicates run as residual filters on those index-ordered scans, which
  stream in output order with no temp B-tree. Add composite `(kind, …)`
  indexes only with measured evidence. Query-plan tests extend the existing
  `CatalogStoreQueryPlanTests` pattern to every new builder.
- The path-ordered `sort_key` remains for enrichment claim ordering even if
  no user-facing sort uses it.

## Enrichment-Driven Reordering

As enrichment lands, `best_capture_unix`, `best_kind`, and `best_format`
change: under date sort an asset's position moves, and under a kind/format
filter its membership can change. The current detail-only fast path (reuse
cached ordered IDs because "enrichment cannot affect membership or order")
is invalidated by this feature and must be redesigned, not patched.

Criteria: correctness of visible order under every descriptor, simplicity
(number of code paths), cost per publication at scale, UI churn.

### RE-A: Always Requery Order On Any Store Change (recommended)

Every dirty publication runs the ordered-ID query for the current descriptor.
The existing published-state equality check already suppresses no-op
publications: when enrichment changed nothing order-relevant, the queried IDs
compare equal and no structural apply reaches AppKit — the cost is one
indexed streaming query per publication tick, bounded by the ~1 Hz cadence
and already measured by `orderQueryMs`.

- Pros: one code path; correct under every descriptor by construction; the
  detail-only/structural classification and its stated assumption disappear
  entirely; Pike-aligned brute force with instrumentation already in place.
- Cons: one query per tick during active enrichment even when the sort is
  enrichment-independent; at the million-item target the per-tick query must
  be proven cheap (the reversal plan is RE-B, not a redesign).
- Failure modes: if the query is ever slow, publication latency grows — the
  existing `orderQueryMs` diagnostics field catches it.

### RE-B: Descriptor-Aware Change Classification

Store notifications become typed (structural scan change vs enrichment
overlay change vs thumbnail-only), and Projection requeries only when the
current descriptor depends on enrichment-affected best values (date sort,
kind/format filter); otherwise it keeps the cached IDs and bumps the detail
generation.

- Pros: zero redundant queries under name/size sort with no filter.
- Cons: two code paths plus a dependency matrix between descriptor fields and
  change kinds; the matrix is a correctness obligation forever (a new
  enrichment-written column must update it).
- Failure modes: a missed matrix entry silently freezes visible order — the
  exact bug class RE-A cannot have.

### RE-C: Keep The Detail-Only Fast Path As Is

- Rejected: visibly wrong order/membership until the next unrelated
  structural event.

RE-A first, RE-B as the measured fallback; FND-043's detail-only reuse
requirement changes accordingly.

### Visual Stability Of 1 Hz Reordering

How a reorder tick reaches glass, and why it neither janks nor visually
churns:

1. Once per second at most, Projection publishes new ordered IDs. The
   published-state equality check drops the publication entirely when the
   order is unchanged — once enrichment settles, ticks stop reaching AppKit.
2. The grid's apply gate serializes applies: one structural apply in flight,
   only the newest pending state retained. A 1 Hz publication rhythm makes
   gate contention rare by construction.
3. AppKit treats `animatingDifferences: false` as a reloadData-class apply, so
   tile correctness cannot depend on preserving item instances. Same-descriptor
   same-membership reorders animate (`animatingDifferences: true`); descriptor-
   changed reorders and large membership applies keep the reloadData-class path
   (ADR 0006 / ARC-023). Measured same-descriptor trickle `applyCallMs` at ~23k
   is in the low tens of milliseconds for small mover counts
   (`docs/research/grid-reorder-cadence-and-appkit-diffable-apply.md`). The
   `MediaGridStructuralApply` signpost still measures this MainActor cost.
4. Scroll stability is a policy choice at apply time, currently
   offset-preserving (same pixel offset, scroll-to-top only on scope change).
   Under date sort during active enrichment, offset preservation means
   content can slide under a stationary viewport as items move above it.
   Options:
   - Offset preservation (current): simplest; acceptable churn at 1 Hz; at
     the top of a newest-first grid, newly dated items appearing at the top
     reads as a live-updating library, which is truthful.
   - Anchor-item preservation: before applying, record the top-left visible
     `MediaAssetID`; after applying, scroll so that item stays put (fall
     back to offset when it left the result set). This is the standard
     photo-browser technique for order churn and is cheap because identity
     is already the structural contract.
   - Recommendation: ship offset preservation first (no new mechanics),
     with anchor-item preservation as the designed next step if real
     enrichment runs feel jumpy. A sort/filter *intent*, by contrast,
     resets scroll to top — the user asked for a new arrangement.
5. After the apply, visible details are re-faulted by ID and existing items
   reconfigure in place; offscreen items are untouched and read fresh detail
   when scrolled in. A tile whose content is unchanged preserves its layer
   contents — no flicker (FND-044 mechanics, unchanged).

Jank and churn are therefore bounded separately: jank by one signposted
main-thread apply per second worst case, churn by non-animated repaints plus
the scroll-stability policy.

## Publication Cadence

Captured direction: background-driven updates (metadata, thumbnails, scan
batches) need at most ~1 Hz. Criteria: perceived responsiveness of direct
user intents, background churn cost, number of timing mechanisms.

### CA-A: Uniform 1 Hz For Everything

- Pros: one knob.
- Cons: sidebar clicks, sort changes, and filter toggles feel broken at up to
  1 s latency; the HIG expectation for direct manipulation is immediate
  response.
- Failure modes: the app reads as laggy precisely at its most interactive
  surface.

### CA-B: Two-Tier — Immediate User Intents, 1 Hz Background (recommended)

One publication loop, one dirty flag, two ways to wake it:

- Background dirt (scan batches, enrichment applies, thumbnail promotions,
  filesystem events) marks dirty and is picked up by the ~1 s timer tick.
- A user intent (descriptor change: scope, filter, sort) marks dirty and
  signals the loop to run now instead of waiting for the tick. The loop's
  existing semantics are untouched: dirty clears before awaited reads, actor
  isolation permits one build at a time, and newer input arriving during a
  build stays dirty for the next pass — the wake signal only changes *when*
  the next pass starts, never *what* it does. The newest-value intent stream
  already coalesces click bursts, so "publish immediately per intent" is
  bounded by human click rate.

Every batching knob in the pipeline aligns to the same ~1 s rhythm, so the
whole background path produces at most about one publication per second
end to end:

- Enrichment: workers append completed results to the pending apply buffer;
  the coordinator flushes it on a ~1 s timer instead of a size threshold. The
  size cap is deleted (captured direction): the buffer is naturally bounded
  by one second of enrichment throughput (thumbnail generation is the rate
  limiter — tens of items per second), and one SQLite transaction of that
  size is trivial. One flush → one Store write transaction → one change
  notification per second.
- Scan persistence cadence: 100 ms → ~1 s. Larger transactions, fewer
  notifications; the existing no-op suppression (FND-062) is unaffected.
- Filesystem-event debounce: 500 ms → ~1 s, one quiet-period rhythm
  app-wide.
- Projection tick: 100 ms → ~1 s for background dirt.
- Viewport priority hints stay newest-value and immediate: they are a cheap
  scroll-driven hint to the enrichment coordinator, not a publication, and
  latency there directly affects which thumbnails appear first.

- Pros: user actions publish at once; background churn drops by an order of
  magnitude across projection, grid applies, and tile reconfigures; the
  size-cap knob disappears entirely — time is the only batching parameter
  left in the enrichment apply path.
- Cons: two latency classes to document and test.
- Failure modes: classifying a genuinely user-initiated path as background
  (or vice versa) — source hygiene can pin the intent list; an unbounded
  apply buffer would matter only if enrichment throughput exploded by
  orders of magnitude, which instrumentation would show first.

### CA-C: Adaptive Cadence

Fast while the user interacts, slow when idle.

- Pros: theoretical optimum.
- Cons: interaction detection, hysteresis, and testing burden for no
  demonstrated need.
- Failure modes: mode flapping; unreproducible timing bugs.

CA-B is the simplest option satisfying both the captured 1 Hz direction and
direct-manipulation responsiveness.

## End-To-End Architecture (Selected Shape)

One value describes the grid query and flows through the seams that already
exist:

```swift
nonisolated struct CatalogQueryDescriptor: Hashable {
    var scope: SidebarSelection
    var filter: MediaFilter        // selected kinds/formats; empty = all
    var sort: MediaSortOrder       // .bestDate(.descending) default, .name, .size
}
```

- View: toolbar menus and menu-bar commands render ViewModel control state
  and call explicit intents (`setMediaFilter`, `setSortOrder`); the custom
  header is deleted; `.navigationTitle` alone carries the name; no count.
  The filtered-empty case renders `ContentUnavailableView` with Clear
  Filters.
- ViewModel: owns immediate control state (FND-023 pattern) and the
  session-lifetime descriptor (plain `@Observable` state; no `@AppStorage` —
  relaunch resets by construction); forwards the descriptor through the
  existing newest-value intent lane; intent arrival wakes the publication
  loop immediately (CA-B).
- Projection: holds the current descriptor; every publication queries ordered
  IDs for it (RE-A); scope normalization generalizes to descriptor
  normalization (removed library falls back to All Media, filter/sort
  survive); empty-state policy gains `noFilterMatches` via the existing
  two-step count check; the loop ticks at ~1 s for background dirt.
- Store: `orderedAssetIDs(matching:availableLibraryPaths:)` composes WHERE
  (roots + best_kind + best_format) and ORDER BY (sort field/direction +
  tiebreak) in `CatalogStorePersistence`; `distinctFilterableTypes(in:)`
  feeds the menu; schema adds scan columns (`kind`, `format`,
  `name_sort_key`), hoisted enrichment columns (`enriched_kind`,
  `enriched_format`), generated `best_*` columns, and the sort covering
  indexes; pre-user destructive reset applies.
- Grid: untouched; sort/filter/reorder changes are ordinary structural
  publications, thumbnail arrivals remain detail refreshes.
- Instrumentation: intents log through the UI category; projection
  diagnostics gain descriptor fields; `orderQueryMs` monitors RE-A's cost;
  cadence changes are visible in existing publication diagnostics.
- Tests: natural-key tests for `name_sort_key`; Store query tests per
  filter/sort combination including NULL best dates and both directions;
  query-plan tests per new builder; generated-column definition tests
  (tile value equals sort value); Projection tests for descriptor
  normalization, `noFilterMatches`, and enrichment-driven reorder
  publication; ViewModel tests for the intent lane and immediate wake;
  source hygiene for one-intent-path and for the retired Swift `??` chains.

Implementation requires: a new ADR (user-facing catalog query surface:
descriptor ownership, best-value schema, index and cadence policy — the
adjacent decision ADR 0010 named), and updates to the corresponding
architecture/product requirement rows, ADR 0006, `docs/architecture.md`, and
APP-001. (Landed as ADR 0011 + APP-013/014.)

## Local Evidence: Filesystem Date Quality (OneDrive Library)

Checked 2026-07-01 in the user's OneDrive camera roll
(`~/Library/CloudStorage/OneDrive-Personal/Pictures/Camera Roll/2026/06/`),
per the user's request, to assess the quality of the `createdAt` fallback for
the pre-enrichment window:

- `20260628_174332.heif` and its Sony RAW sibling `20260628_174332.arw`:
  birthtime and mtime are both exactly `2026-06-28 17:43:32 -0700`, matching
  the filename's capture time. Spotlight's EXIF-derived
  `kMDItemContentCreationDate` (`2026-06-29 00:43:32 +0000`) is the same
  instant.
- A random 8-file sample (HEIF/ARW/MP4): birthtime == mtime for all, and the
  stills all match their filename timestamps.
- One instructive exception: `20260604_193512.mp4` has filesystem dates of
  `12:35:12 -0700` — the same instant as the filename's `19:35:12`, which is
  UTC. The camera names videos with UTC wall-clock while the filesystem dates
  are the correct instant. Filenames are therefore not reliable date carriers
  even in this disciplined library, while filesystem dates are — and
  QuickTime's UTC-based timestamps are exactly why the ranking's offset
  handling matters.

The `_iOS` camera-upload population (1,271 files in that month alone) behaves
completely differently:

- An 8-file random sample shows filesystem birthtime/mtime that are
  **upload/sync artifacts**, hours to days after the capture instant encoded
  in the filename; one file's birthtime even postdates its mtime.
- Most sampled `_iOS` files are dataless placeholders (`ls -lO` shows
  `dataless`), so Spotlight's EXIF-derived date falls back to filesystem
  dates for them — no embedded date is readable without materialization.
- A **materialized** iOS still (`20260606_234221294_iOS.heic`) proves
  enrichment fixes this: its EXIF capture date is `2026-06-06 23:42:22 UTC`,
  matching the filename's encoded instant, while its filesystem dates are
  about seven hours later. One materialized iOS video's Spotlight content
  date equaled its filesystem date instead of the filename instant —
  whether the QuickTime atom itself is wrong or Spotlight fell back is
  unresolved; verify with the MediaMetadata reader during implementation.
- Filename conventions differ per source (Sony stills encode local time, iOS
  uploads encode UTC), so filenames are not reliable date facts and are not
  parsed (MED-002-adjacent: heuristics that fabricate instants are avoided).

Conclusions: for non-iOS camera files OneDrive preserves true capture
instants in filesystem dates, so the fallback is excellent; for iOS
camera-upload files the filesystem dates are wrong by hours-to-days until
enrichment reads embedded metadata. Date-sorted grids over this library will
therefore genuinely re-order as enrichment lands — enrichment-driven
reordering (RE-A), the ~1 Hz publication rhythm, and the scroll-stability
policy are load-bearing for real data, not theoretical. The RAW+HEIF sibling
pair also confirms the RAW kind will appear alongside Images in real data.

## Open Questions

All resolved (user-confirmed 2026-07-01): the raw-stills kind is labeled
"RAW"; all four background-coalescing knobs are a flat 1.0 s; background
reorders preserve pixel scroll offset with anchor-item pinning deferred
until real enrichment runs prove it necessary. Implementation planning lives
in `docs/plans/0030-toolbar-sort-filter-query-surface-plan.md`.

## Sources

- [WWDC25: Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/)
- [WWDC25: Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [WWDC25: Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/)
- [Apple: Toolbars (SwiftUI documentation)](https://developer.apple.com/documentation/swiftui/toolbars)
- [Apple: ToolbarSpacer](https://developer.apple.com/documentation/SwiftUI/ToolbarSpacer)
- [Apple Newsroom: the new software design](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/)
- [Create with Swift: Adapting search to the Liquid Glass design system](https://www.createwithswift.com/adapting-search-to-the-liquid-glass-design-system/)
- [SQLite: Generated Columns](https://www.sqlite.org/gencol.html)
- [SwiftUI new toolbar features summary (Xcode 27 additional documentation mirror)](https://github.com/artemnovichkov/xcode-27-system-prompts/blob/main/AdditionalDocumentation/SwiftUI-New-Toolbar-Features.md)
