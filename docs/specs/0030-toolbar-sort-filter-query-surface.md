# Spec: Toolbar Sort/Filter Query Surface

## Classification

- Work type: Feature
- Current requirement IDs: FND-002, FND-006, FND-014, FND-019, FND-023,
  FND-024, FND-038, FND-043, FND-044, FND-061, FND-062, APP-001, APP-006,
  APP-010, APP-013, APP-014, ENR-003, ENR-005, ENR-009
- Future idea or candidate links explicitly requested by the user:
  `docs/plans/0030-toolbar-sort-filter-query-surface-plan.md`,
  `docs/research/toolbar-sort-filter-architecture.md`
- ADRs: ADR 0011

## Problem

The current browser repeats the selected library name inside the content pane,
shows a file count the user does not want, and has no user-facing sort/filter
controls. Ordering is fixed to the path-oriented `sort_key`, while the displayed
date is a Swift fallback chain over a pre-resolved metadata winner and filesystem
dates. That makes date sorting unsafe because the tile and SQL would need
parallel definitions.

Before implementation, repo inspection for this increment found:

- `MediaGridView` renders `header` plus `Divider` and also sets
  `.navigationTitle`.
- `CatalogWindowViewModel` has one newest-value sidebar intent lane and one
  lossless add/remove lane.
- `CatalogProjection` owns off-main publication but still reuses cached ordered
  IDs for `.assetsDetailChanged` based on the old assumption that enrichment
  cannot affect membership or order.
- `CatalogStorePersistence` stores `capture_date_unix`, persists full metadata
  JSON in `asset_metadata`, and already owns ordered-ID query builders.
- `MediaEligibility` computes scan-time image/movie eligibility from `UTType` but
  does not persist kind or format.
- `EnrichmentCoordinator` flushes writes by batch size.

## Scope

In scope:

- native toolbar and menu-command sort/filter controls
- no in-content title/count header
- session-only descriptor state for sidebar scope, media filter, and sort order
- SQLite scan/enrichment facts and generated best values
- Store-owned ordered-ID, unfiltered-count, and filter-option queries
- always-requery projection publication for descriptor truth
- no-filter-matches empty state with Clear Filters
- background cadence retune to roughly one second with immediate user-intent
  publication
- focused tests, requirements, ADR/spec updates, onboarding, source comments,
  and stale-doc audit

Out of scope:

- search
- media selection, activation, preview, edit, import, export, or inspector UI
- parsing dates from filenames
- audio-specific behavior
- anchor-item scroll preservation beyond current offset preservation
- composite filter-by-sort indexes beyond the current measured query-plan set

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected.
- [x] Captured user guidance is restated as precise requirements for user
      verification.
- [x] Observable current requirements and acceptance examples are listed.
- [x] Future ideas and unimplemented requirement candidates are separated from
      `docs/requirements.md`.
- [x] Roadmap, planning, or idea documents are ignored except
  `docs/plans/0030-toolbar-sort-filter-query-surface-plan.md` and the
      linked research note, which the user explicitly asked to implement.
- [x] Ownership, side effects, persistence, cancellation, errors, progress,
      privacy, instrumentation, and tests are addressed.
- [x] At least three alternatives are compared.
- [x] Refactor retirement proof is defined.
- [x] A repository-wide stale-document audit is defined for affected ADRs,
      specs, requirements, process docs, onboarding walkthrough, indexes,
      templates, scripts, and backlinks.
- [x] A code-comment accuracy audit is defined for affected architecture,
      concurrency, persistence, diagnostics, and AppKit boundaries.
- [x] Performance/jank evidence is defined.
- [x] Open questions are answered or out of scope for this increment.

The captured direction is explicit in
`docs/plans/0030-toolbar-sort-filter-query-surface-plan.md`; implementation can proceed
without another clarification pause because the user asked to implement that plan
as the increment.

## Captured Requirements For User Verification

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| TSF-001 | Functional | The media browser shall have no in-content header, no duplicated library title, and no item count. | Current | `docs/requirements.md`, this spec |
| TSF-002 | Functional | The window title alone shall carry the library name. | Current | `docs/requirements.md`, this spec |
| TSF-003 | Functional | Toolbar and menu commands shall filter by Images, RAW, and Videos, with only formats present in the current scope shown below each kind. | Current | `docs/requirements.md`, this spec |
| TSF-004 | Functional | RAW shall mean raw still images only; all videos stay under Videos. | Current | `docs/requirements.md`, this spec |
| TSF-005 | Functional | Sort fields shall be best date, file name, and file size. Best date defaults newest first, name defaults ascending, and size defaults largest first. | Current | `docs/requirements.md`, this spec |
| TSF-006 | Functional | Tile display date, date sort, and future current date consumers shall read the same best available date: metadata role facts first, then filesystem creation date, then modification date. | Current | `docs/requirements.md`, this spec |
| TSF-007 | Architecture | Best date, kind, and format shall be generated SQLite best values from persisted scan and enrichment facts, with no pre-resolved winner stored and no Swift ranking policy. | Current | ADR 0011, `docs/requirements.md` |
| TSF-008 | Functional | Sort and filter shall persist for the session only and reset on relaunch. | Current | `docs/requirements.md`, this spec |
| TSF-009 | Non-functional | Direct sidebar, sort, and filter intents shall publish immediately; background scan, enrichment, thumbnail, and filesystem-event updates shall coalesce at roughly one second. | Current | `docs/requirements.md`, this spec |
| TSF-010 | Architecture | Enrichment may change sort position and filter membership, and Projection shall treat that as ordinary correct catalog truth. | Current | ADR 0011, `docs/requirements.md` |
| TSF-011 | Non-functional | Enrichment flushing shall be time-based; the fixed apply-batch size cap shall be retired. | Current | `docs/requirements.md`, this spec |
| TSF-012 | Regression | Sidebar and descriptor changes reset grid scroll to top; background reorders preserve scroll offset. | Current | `docs/requirements.md`, this spec |

## Architectural Alternatives

### Alternative A: UI/Projection-Side Filter And Sort

Pros:

- few persistence changes
- visible toolbar can be built quickly

Cons:

- reintroduces full-value projection sorting/filtering
- duplicates date ranking in Swift and SQL once persistence is queried
- does not give Store one query owner

Failure modes:

- tile date and sort position drift
- MainActor or Projection hot paths grow with full asset values
- enrichment-driven membership changes need special invalidation cases

### Alternative B: Store Pre-Resolved Best Winners

Pros:

- simple query columns
- easy detail model mapping

Cons:

- stores policy results instead of facts
- changing ranking later is expensive or requires file re-reads unless all facts
  are also stored
- repeats the retired `capture_date_unix` winner pattern

Failure modes:

- stale winner columns survive policy changes
- scan and enrichment writers can silently disagree about kind/format vocabulary

### Alternative C: Store Facts And Generate Best Values In SQLite

Pros:

- one best-value policy for query and display
- facts remain rebuildable and reusable
- direct match to Store-owned indexed query architecture
- keeps views passive

Cons:

- larger schema and more query-plan tests
- clean destructive reset required
- sparse filters might need measured composite indexes later

Failure modes:

- missing facts in scan upsert suppression hide visible changes
- direction-specific query indexes can be incomplete if tests do not cover them

Alternative C is selected.

## Selected Approach

Implement ADR 0011 in one feature increment. The selected approach is right for
Otos because the filesystem remains the source of media truth, the catalog stays
a rebuildable projection, and the UI expresses a query rather than owning query
logic. It is also the simplest correct approach: one descriptor, one persistence
owner, one best-value ranking, and one publication boundary.

## Interfaces, Ownership, And Data Flow

- `CatalogQueryDescriptor`: scope, `MediaFilter`, and `MediaSortOrder`.
- `MediaKind`: image, raw, video. Scan classification uses `UTType.rawImage`
  before `UTType.image`, then `UTType.movie`.
- `MediaFormatToken`: normalized uppercase extension token shared by scan and
  enrichment writers.
- `CatalogFilterOptions`: Store-published scoped kind/format options for menus.
- ViewModel owns session descriptor state and forwards newest descriptor intents.
- Projection normalizes descriptor scope, builds filter options, asks Store for
  ordered IDs, chooses empty state, and publishes `CatalogWindowState`.
- Store owns SQL, schema, scans, enrichment writes, and query builders.
- SwiftUI toolbar/menu commands and empty-state Clear Filters call ViewModel
  intents. They do not inspect SQLite or derive catalog truth.
- AppKit grid receives a descriptor-bearing `CatalogMediaGridState`; descriptor
  changes reset scroll, while same-descriptor background reorders preserve offset.

Persistence effects:

- destructive reset from the old pre-user schema
- new scan fact columns: `kind`, `format`, `name_sort_key`
- new enrichment fact columns: timestamp role instants plus enriched kind/format
- new generated columns: `best_capture_unix`, `best_kind`, `best_format`
- retired `capture_date_unix`

Concurrency:

- UI state assignment remains MainActor in ViewModel.
- Query work remains in Store/Projection actors off MainActor.
- User descriptor intents use newest-value delivery.
- Add/remove mutations stay lossless serial.
- Enrichment coordinator owns time-based result flushing and cancellation at
  teardown.

Privacy and media-originals effects:

- No original files are modified, moved, deleted, or sidecar-written.
- Scanner still reads filesystem facts only.
- Enrichment byte-read safety remains the existing ADR 0008 materialization gate.
- Logs keep bounded scalar fields and do not include metadata blobs or thumbnail
  bytes.

## Retirement Proof

- `rg "capture_date_unix|idx_media_asset_capture_date|resolveCaptureDate|applyBatchSize|MediaGridView.header|files"` after implementation, with expected remaining
  matches only in retired docs if explicitly marked.
- Query-plan tests cover production builders and verify the selected indexes avoid
  temp sorting for covered sort directions.
- Source-hygiene tests prove the in-content header/count are absent and toolbar
  commands call ViewModel intents.
- Projection tests prove enrichment detail changes can requery order, descriptor
  intents are immediate, and no-filter empty state is distinct.
- Store tests prove scan writes kind/format/name key, enrichment writes role
  facts, best date comes from the generated column, and no-op scan suppression
  includes new visible facts.
- Coordinator tests prove time-based flushing without `applyBatchSize`.

## Living Documentation And Comment Audit

Update current docs:

- `docs/requirements.md`
- `docs/index.md`
- `docs/onboarding.md`
- ADRs 0002, 0005, 0009, 0010, and new 0011
- specs 0004, 0007, 0009, 0011, 0012, 0014, 0022, 0025, and new 0030

No process docs, templates, or scripts need semantic changes unless verification
shows their current commands or checklists are stale.

Code comments/file guides to update:

- `CatalogModels.swift`
- `CatalogStorePersistence.swift`
- `CatalogStore.swift`
- `CatalogProjection.swift`
- `CatalogWindowViewModel.swift`
- `EnrichmentCoordinator.swift`
- `MediaEnricher.swift`
- `MediaGridView.swift`
- `MediaAssetCollectionView.swift`

## Instrumentation And Performance

- Keep `CatalogStoreOrderedAssetIDQuery`, `CatalogWindowPublication`,
  `CatalogWindowStateBuild`, `CatalogWindowStateApply`,
  `MediaGridStateReceive`, `MediaGridStructuralApply`,
  `CatalogScanBatchWrite`, and `CatalogEnrichmentBatchWrite` signposts.
- Continue JSONL diagnostics for Store/query/projection summaries with bounded
  counts, descriptor strings, query times, equality times, and empty-state names.
- Verify unified log availability with `script/logs.sh Catalog` if a run is
  possible in the agent environment.
- Run `script/verify.sh`.
- Use `script/profile.sh "Animation Hitches" 10s` or another profile only if the
  app can be launched and interacted with in the agent environment; otherwise
  record the blocker and rely on signpost/log/build/test evidence.

## Code-Smell Review

- MainActor gravity: descriptor controls update MainActor state only; query work
  stays in actors.
- SwiftUI body work: menus render projected option values and call intents; no
  sorting/querying in `body`.
- State duplication: `CatalogQueryDescriptor` is the only session query state.
- Stringly typed domain facts: kind and format use typed wrappers/enums outside
  persistence.
- Test coupling: query-plan tests use production SQL builders.
- Diagnostic payload sprawl: logs remain scalar and bounded.
- AppKit bridge sprawl: reset policy extends existing descriptor state; AppKit
  does not own query semantics.

## Acceptance Criteria

- Opening the app shows toolbar sort/filter controls, no in-content header, and
  no item count.
- Grid defaults to best-date newest first.
- Filtering to a kind or format shows only matching assets, and Clear Filters
  restores the full scoped query.
- Filter menus list only kinds/formats present in the current sidebar scope.
- Sort and filter controls echo immediately.
- Background scan/enrichment/thumbnail/filesystem changes coalesce around one
  second.
- Enrichment can move an item to its metadata-date sort position and update
  filter membership.
- Tile date equals the generated best date used for date sort.
- Sidebar/sort/filter changes reset scroll to top; same-descriptor background
  reorders preserve offset.
- Relaunch resets sort/filter to defaults.
- Toolbar and menu commands call the same ViewModel intents.

## Verification

- Local checks: `script/verify.sh`, `xcodebuild -version`
- Focused tests: Store query-plan tests, Store enrichment and scan-freshness
  tests, Projection tests, ViewModel tests, AppKit apply-gate tests,
  source-hygiene tests, MediaEligibility tests, MediaAsset tile tests
- Performance/log evidence: query-plan output, existing signpost/log categories,
  `script/logs.sh` or documented launch/log blocker
- Stale-document audit: `rg` for retired symbols and old cadence/order claims in
  current docs
- Code-comment accuracy audit: touched architecture boundary comments reviewed
  against landed implementation
- CI expectations: fast remote CI should run; local Xcode 27 `script/verify.sh`
  remains required evidence
