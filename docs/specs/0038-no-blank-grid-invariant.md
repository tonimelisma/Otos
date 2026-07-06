# Spec 0038: No-Blank Grid Invariant

## Status

Implemented in this increment. Spec 0039 is the post-review correction for the
grid preheater and structural-apply policy: it keeps this spec's no-blank tile
invariant, batches look-ahead detail reads, makes decoded-cache warming
non-main-actor, and applies the reloadData fallback after measured true-diff
apply cost.

## Classification

Bug fix, rendering architecture, performance/instrumentation, and refactor.

## Problem Statement And User-Facing Goal

The media grid could visibly blank thumbnails that had already painted whenever
large reorder-only structural applies, missing visible-detail rows, failed detail
queries, transient thumbnail decode failures, or scroll-back reuse forced a
placeholder-first paint path. The goal is a hard user-facing invariant: once a
thumbnail has painted for an on-screen asset in the current process, the tile must
keep showing that thumbnail, or a newer thumbnail for the same asset, until it is
reused for a different asset.

The same increment tightens thumbnail overlay geometry and shortens attribution
for stalled cloud materialization by re-issuing non-blocking provider download
requests and reserving download capacity for viewport-dataless files.

## Captured User Guidance For Verification

The owner explicitly approved `PLAN.md` by asking the agent to "implement
PLAN.md completely. all increments, provide the DOD report after each increment
but don't stop after the first increment. do all the increments before stopping."
The approved guidance is recorded as current implementation direction here, not
as roadmap material. It splits into these current requirements:

- Functional: the media grid never blanks a thumbnail that has already been
  displayed for the same on-screen asset.
- Regression: reorder-only applies, detail-query failures, missing detail rows,
  nil thumbnail loads, scrolling back within cache bounds, enrichment churn, and
  availability churn must not render placeholder content over a painted same-asset
  thumbnail.
- Architecture: decoded thumbnail reuse is a bounded rendering-only memory cache
  owned by the window ViewModel and passed into the AppKit grid; it is never
  catalog truth and is never persisted.
- Architecture: structural apply correctness cannot depend on AppKit reload
  semantics; synchronous tile paint and same-identity downgrade guards enforce
  the invariant even if AppKit recycles visible items.
- Non-functional: performance-sensitive rendering changes must be verified with
  local tests and smoke/log/profile evidence where the environment permits.
- Process: stale docs that claimed large nonanimated reorders were the flicker fix
  must be rewritten to name the reloadData fact and the new invariant.
- Privacy: the increment reads app-owned thumbnails and cloud materialization
  status only; it does not write originals or user media folders.

## Current Repo State

Inspection before implementation found:

- `AGENTS.md` did not yet name the no-blank grid rule as a non-negotiable
  invariant.
- `docs/requirements.md` had APP-006 and APP-010 acceptance text that still
  described large reorder-only nonanimated applies as preserving rendered
  thumbnails.
- ADR 0006 claimed large same-membership background reorders apply nonanimated
  while preserving item identity. The macOS 27 AppKit header states that
  `apply(_:animatingDifferences: false)` uses `reloadData`, so that claim was
  wrong.
- ADR 0009 explicitly rejected any in-memory thumbnail cache as a future-only
  decision; current evidence now justifies a bounded rendering cache.
- `docs/onboarding.md`, specs 0024, 0035, 0036, and 0037 each carried stale
  rendering or overlay geometry claims that this increment supersedes.
- `MediaAssetTileView` loaded every new image asynchronously and allowed nil
  loads or missing detail rows to clear a painted same-asset layer.
- `MediaAssetCollectionViewController` kept only the current visible detail map,
  wiping it on query failure, and disabled animation for large reorder-only
  applies.
- `FileMaterialization.materialize` issued one provider download request and
  waited up to 120 seconds without a re-request; the coordinator allowed eager
  downloads to occupy all download slots.

## In Scope

- Promote the approved plan into this decision-complete spec and update current
  requirements, ADRs, onboarding, index, stale specs, and affected file guides.
- Add a bounded decoded-thumbnail memory cache for rendering reuse only.
- Change tile paint policy so cached images paint synchronously, same-identity
  information loss keeps the current image, nil loads do not clear a painted
  image, and placeholder is legal only before an asset has ever decoded in this
  process.
- Keep visible-detail knowledge sticky with bounded LRU eviction and add a
  preheating path that faults details and warms decoded thumbnails ahead of the
  viewport.
- Apply large reorder-only changes without visible thumbnail blanking. The
  initial implementation used true diffable applies under duration-zero animation
  suppression; spec 0039 applies the documented reloadData fallback after measured
  multi-second true-diff apply cost.
- Move overlay scrims to the thumbnail corners and size the text scrim to text.
- Re-issue cloud materialization requests on a cadence inside the timeout, reserve
  one download slot for viewport-dataless assets, and record materialization
  outcome details.

## Out Of Scope

- Reorder damping, batching, slowing, or projection cadence changes.
- Thumbnail resolution changes.
- New persistence schema or persisted materialization status.
- Import, export, preview, zoom, drag, edit, or original-writing behavior.
- App Sandbox, security-scoped bookmarks, sidecars, or any writes into user media
  folders.

## Linked Current Requirement IDs

FND-002, FND-006, FND-014, FND-015, APP-006, APP-010, ENR-002, ENR-004,
ENR-008, ENR-009, and ENR-010.

---

## 0. The invariant (STEP ONE — written before any code changes)

> **The media grid never blanks. A tile whose thumbnail has been displayed never
> renders anything other than that thumbnail (or a newer thumbnail for the same
> asset) while the asset is on screen — regardless of reorders, scans,
> enrichment, structural applies, detail-query failures, scrolling,
> availability churn, or any other background activity. Placeholder content is
> permitted only for an asset whose thumbnail has never yet been decoded in
> this process. Zero occurrences; no mitigating factors.**

Written into, in this order, before any code lands:

| File | Change |
| --- | --- |
| `AGENTS.md` | New bullet under **Non-Negotiable Principles** (same class as "exactly one main window"). |
| `docs/requirements.md` | New APP row (functional + regression) with acceptance examples: "given a reorder-only structural apply while N thumbnails are visible, zero visible tiles render placeholder content"; "given a tile-detail query fails or returns no row for a visible painted asset, the painted thumbnail stays"; "given the user scrolls back to a previously displayed asset within cache bounds, the thumbnail appears with no placeholder frame". Amend APP-006 and APP-010 acceptance text to reference the invariant. |
| `docs/adr/0006-catalog-grid-rendering.md` | Record: (a) the AppKit fact that `apply(animatingDifferences: false)` **is** `reloadData` (macOS 27 SDK header `NSDiffableDataSource.h:105`, no `applySnapshotUsingReloadData` exists in AppKit); (b) the synchronous-paint architecture (§3) as the invariant's enforcement, deliberately independent of apply semantics. |
| `docs/adr/0009-enrichment-storage-and-staleness.md` | Bounded in-memory decoded-thumbnail cache recorded as a measured, justified rendering structure (evidence §1); rendering state only, never truth; disk thumbnails remain the durable product. |
| `docs/onboarding.md` | Rewrite the grid section — it currently documents the flicker mechanism as intended behavior ("large same-membership background reorders apply nonanimated"). |
| `docs/specs/0024`, `0035`, `0036` | Stale-claim audit: each recorded "nonanimated large reorders" as the fix for animated-reorder jank without knowing that is reloadData on AppKit; annotate and point to 0038. |
| `docs/specs/0037` | Note: overlay geometry superseded by 0038 (0 px corners, text-sized scrim). |

Explicitly rejected and out of scope: reorder damping, batching, or slowing.
Reorders continue at natural cadence; they stop destroying rendered content.

---

## 1. Evidence and the complete blanking-vector inventory

Baseline session `catalog-diagnostics-20260705T050945Z` (22:09–22:18, 22,523
OneDrive assets): 153 structural applies in 8.6 min, all `reorderOnly=true`,
66–90 ms each; 76 main-run-loop stalls (p50 200 ms, max 856 ms); tile-detail
SQLite query never exceeded the 50 ms slow threshold (zero
`catalog.store.query.tileDetail` records); thumbnail decode benchmarked on 200
real thumbnails: p50 0.8 ms / p90 1.0 ms / max 10.6 ms (20 KB JPEGs). Neither
storage stage is slow; the paint pipeline's structure is the defect.

Every way the grid can blank today. The fix (§3) closes all five by
construction, not case by case:

| # | Vector | Mechanism (file:line) |
| --- | --- | --- |
| V1 | **reloadData applies.** Large reorder-only snapshots apply with `animatingDifferences: false`, which AppKit documents as reloadData: every visible item is torn down, `prepareForReuse` wipes the painted layer, and recreated items paint via V2. Fired every ~3.4 s during enrichment. | Policy `MediaAssetCollectionView.swift:325–344` (`largeReorderAnimationItemLimit`), apply `:322` |
| V2 | **Placeholder-first paint for every freshly created item** (scroll-in or apply-in). The item provider must return synchronously, but the visible-detail map holds only the previous viewport, so the provider fabricates an empty `MediaAsset` (no `thumbnailPath`, `assetForTile`), the tile paints gray, and real content arrives only after detail query → reconfigure → detached decode → main-actor apply. | Provider `:148–158`, fallback `:466–476`, async refill `:378–401`, tile async-only load `MediaAssetTileView.swift:208–234` |
| V3 | **Same-identity downgrade.** `reconfigureVisibleItems` re-configures visible tiles from the map; if the map lost a row — `MediaTileDetailReader.assets` returns `[:]` on any query error (`MediaAssetCollectionView.swift:63–74`), or the row is simply absent — the content key collapses from `"t.jpg#s#m"` to `"#-1#-1"`, a load of nothing is spawned, and `layer.contents = nil` lands on a painted tile. The tile tracks no asset identity, so it cannot defend itself. | `MediaAssetTileView.swift:196–203`, nil apply `:226–228`; map replace `MediaAssetCollectionView.swift:389` |
| V4 | **Nil-image apply on a legitimate key change.** Re-enrichment changes the stamp; if the new thumbnail file is transiently unreadable, the load resolves `nil` and is applied over the painted image. | `MediaAssetTileView.swift:227` (no nil guard) |
| V5 | **No synchronous repaint source.** `prepareForReuse` correctly clears reused tiles, but configure can only start an async load — even for a thumbnail decoded two seconds ago — so scroll-back always flashes placeholder. | `MediaAssetTileView.swift:236–256`, no cache anywhere (`ThumbnailStore.load` is uncached disk decode) |

Materialization (issue 4), traced per asset: 51 of 54 completed viewport assets
went claim → thumbnail in 0–2 s. The three slow ones (40 s / 162 s / 193 s) share
one shape — e.g. `20260627_153916.arw`: queued dataless 05:14:48 → ~39 s waiting
for one of 4 download slots (all busy with eager full-library downloads) →
**120 s poll timeout during which OneDrive never materialized the file** →
failed 05:17:27 → automatic re-claim issued a **fresh download request →
materialized 2 s later** → thumbnail 05:17:30. Transfers take seconds; the
minutes are one stalled provider request + a dead 120 s poll + slot contention.
Instrumentation gaps that hid it: `MaterializationOutcome` case discarded
(`EnrichmentCoordinatorCompletion.swift:31`), no download-dispatch event,
`FileMaterialization` logs nothing, no byte sizes.

---

## 2. The pattern, and what is verified vs. de-risked

**Pattern** (Apple's published photo-grid architecture — `PHCachingImageManager`
/ `startCachingImages` preheating + synchronous cell paint from a bounded
memory cache; `NSCollectionViewPrefetching`'s header comment names thumbnail
acquisition as its purpose): decoded thumbnails live in a bounded in-memory
cache keyed by content identity; cells paint synchronously from it; a preheater
fills it just ahead of the viewport. Photos.app's internals are not public; we
adopt the published pattern natively (no PhotoKit — our assets aren't in the
system library).

Epistemic ledger — every external dependency, its status, and its fallback:

| Dependency | Status | Probe | Fallback (invariant survives) |
| --- | --- | --- | --- |
| `animatingDifferences: false` = reloadData on AppKit | **Verified** (macOS 27 SDK header on this machine; docs) | — | — (this is the bug, not a dependency) |
| Diffable `apply(animatingDifferences: true)` preserves item instances for moves | Standard AppKit batch-update semantics, but post-0038 live evidence found true-diff large/reorder applies too expensive | Signpost the apply wall time and `MediaTilePrepareForReuse` count per apply on the 25k library | Spec 0039 uses `false` (reloadData), visually correct because §3 paint is synchronous |
| `NSAnimationContext` duration 0 suppresses batch-update animation | Retired for the current large/reorder path by spec 0039 after measured apply cost | — | Same as above |
| `prefetchDataSource` fires with compositional layout + diffable on current macOS | API **verified present** (SDK header, macOS 10.13+), but timing is opportunistic; the review evidence saw only one callback and the spec 0039 smoke saw 10 | Counter on `prefetchItemsAt` calls in smoke run | Manual look-ahead: fault details + warm decode for `layoutAttributesForElements(in: visibleRect ±2 pages)` on scroll ticks; spec 0039 makes this the primary batched path |
| Decoded cache is thread-safe, cost-bounded, and usable off-main | Implemented as a `Mutex`-protected rendering cache in spec 0039 | Hit/miss/insert counters | — |
| OneDrive honors a re-issued `startDownloadingUbiquitousItem` | **Observed twice** in traces (2–3 s success immediately after re-request) | WS6 instrumentation makes every download attempt attributable | Timeout/retry loop already exists and now costs ≤ ~30 s, not 120 s |

Crucially: **the invariant depends only on the cache + paint policy (pure code
we own). Prefetch and apply semantics only affect how often the cold-first-paint
path runs and how much work applies waste.** That is what makes the plan
ironproof — no AppKit behavior can violate the invariant once configure paints
synchronously and never downgrades.

---

## 3. Exact change inventory

### 3.1 New file: `Otos/Views/MediaTileImageCache.swift`

Single owner of decoded-thumbnail reuse. The current implementation is a
nonisolated `final class`, `Sendable`, protected by `Synchronization.Mutex`, and
keyed by the existing `imageContentKey` string. `totalCostLimit` ≈ 128 MB with cost =
`bytesPerRow × height` (decoded 256 px bitmap ≈ 190 KB → ~650 entries ≈ many
screenfuls at 6 columns); count limit as a secondary bound. Keys embed the
enrichment stamp, so invalidation is automatic — a re-enriched asset produces a
new key and stale entries age out. API: `image(for:)`, `insert(_:for:)`.
Signpost counters: hit / miss / insert. Rendering state only: never persisted,
never consulted for truth. File guide states this and the ADR 0009 linkage.

Ownership: `CatalogWindowViewModel` — the same pattern as
`mediaTileDetailReader` (stored `@ObservationIgnored private let` at
`CatalogWindowViewModel.swift:65`, accessor like `:50–52`). **Not**
controller-owned: `MediaGridView.swift:18–31` swaps to `emptyContent` whenever
the grid is empty, tearing down the whole `NSViewController`; a
controller-owned cache would die on every filter/scope transition through
empty. Passed down exactly like `thumbnailDirectory`:
`ContentView.swift:27–37` → `MediaGridView` property → representable property
(`MediaAssetCollectionView.swift:31–54`) → controller var (set in
`updateNSViewController`, `:43–53`).

### 3.2 `Otos/Views/MediaAssetTileView.swift` — paint policy (closes V1–V5)

New tile state: `currentAssetID: MediaAssetID?` alongside
`currentImageContentKey` — identity is what the downgrade guard needs and the
tile does not have today.

`configure(asset:thumbnailDirectory:cache:)` becomes a pure decision followed
by mechanical application. New
`MediaAssetTilePresentation.paintDecision(...) -> TilePaintDecision`, a pure,
unit-tested function of `(incoming key, incoming thumbnailPath, current key,
current identity, incoming identity, cacheHasImage)`:

| Case | Decision |
| --- | --- |
| Cache hit for incoming key | `.paintCached` — assign `layer.contents` synchronously; no task; closes V1/V2/V5 (recreated or reused tiles repaint in the same layout pass, so even a reloadData-class apply cannot blank) |
| Incoming key == current key | `.keepCurrent` (exists today) |
| Same identity, incoming has **no** `thumbnailPath` (detail row missing/downgraded) | `.keepCurrent` — never downgrade painted content on information loss; closes V3 |
| Different identity or new key, `thumbnailPath` present, cache miss | `.loadAsync` — keep placeholder only if nothing painted; start load |
| `thumbnailPath == nil`, nothing painted | `.placeholder` — the only legal placeholder; **no detached task spawned** (today one is wasted per blank tile, `:202`) |

Async apply block (`:218–232`): insert decoded image into the cache from the
detached task before hopping to main; on main, **apply only non-nil images** —
a nil load result leaves painted content in place (closes V4) and logs. Delete
the vestigial `imageView.image = nil` (`:226`; `.image` is never set anywhere).

**Invariant watchdog**: the one mutation point that assigns `layer.contents`
asserts the invariant — if painted content would be replaced by nil/placeholder
for the same identity, emit `MediaTilePaintInvariantViolation` (signpost +
`OtosLog.ui.error`). Acceptance: zero occurrences in the verification run.
Unit test drives the decision table directly.

Review fixes riding along: `MediaGridSlowCellConfiguration` error→debug
(threshold reviewed post-fix; `:53–62`); `accessibilityLabel` takes badge text
as a parameter instead of reading `durationField.stringValue` view state
(`:365–374`).

### 3.3 `Otos/Views/MediaAssetCollectionView.swift` — details always at hand

- **Sticky detail map** (closes V2's data half, V3's map-wipe half): replace
  wholesale assignment `tileDetailsByID = assets` (`:389`) with merge + bounded
  LRU (cap ~4,096 entries ≈ ~1 MB; recency-ordered eviction; constants in one
  place, instrumented). Query errors merge nothing — they no longer erase
  knowledge (today `[:]` from `MediaTileDetailReader.assets` `:63–74` wipes the
  map for the whole viewport).
- **`assetForTile` (`:466–476`)** unchanged in signature; with the sticky map
  its placeholder branch becomes rare (only never-seen identities), and §3.2
  makes that branch invariant-safe anyway.
- **Preheating**: adopt `NSCollectionViewPrefetching` behind a small
  `TilePreheater` seam. `loadView` (`:122`) sets
  `collectionView.prefetchDataSource = self`; `prefetchItemsAt` maps index
  paths → IDs via `dataSource.itemIdentifier(for:)`, batch-faults details
  through the existing `MediaTileDetailReader` into the sticky map, and
  warm-decodes into `MediaTileImageCache` off-main; `cancelPrefetching` cancels
  pending decodes. Spec 0039 corrected the initial one-task-per-ID
  implementation: both AppKit prefetch and manual look-ahead now share one
  batched newest-burst task, and manual look-ahead is the primary path because
  AppKit prefetch timing is opportunistic. Reorder churn can stale prefetched
  positions — harmless, cache and map are identity-keyed.
- **Apply semantics** (closes V1's wasteful half): delete
  `largeReorderAnimationItemLimit` and the `animatingDifferences` policy
  (`:79`, `:325–344`). The initial implementation ran all applies with
  `animatingDifferences: true` and wrapped reorder-only/large applies in a
  zero-duration animation context. Spec 0039 applies the fallback after live
  evidence showed multi-second true-diff applies: large/reorder applies now use
  `animatingDifferences: false`, while small user-visible insert/removes keep
  animation. ADR 0006 owns the current policy.
- Unchanged: apply gate (`MediaAssetCollectionApplyGate` — reviewed, correct),
  selection snapshot/restore (`MediaAssetCollectionSelection.swift:69–80`),
  viewport reporting, scroll-driven detail refresh cadence, diagnostics fields
  (gain `preheatCount`).

### 3.4 Overlay geometry (issues 2 + 3) — `MediaAssetTileView.swift`

- `Layout.overlayInset` 6 → 0 (`:85`): scrim anchored exactly at the
  thumbnail's top-left corner (`layoutTextScrim` x/y, `:298–303`), badge exactly
  at bottom-right (`layoutVideoBadge`, `:339–344`). No padding between text
  block and the two edges it touches; keep small internal padding only on
  inner (away-from-corner) edges.
- Scrim width: `max(titleField, dateField).intrinsicContentSize.width` +
  inner padding, capped at tile width (`:294–303` currently full-width) — the
  darkened area sits only under the text.
- `maskedCorners` rounds only each overlay's inner corner; outer corners are
  clipped by the tile's existing 4 pt mask.
- `overlayVisibility` thresholds (`:451–456`) recomputed for 0 px geometry;
  stays pure and unit-tested.

### 3.5 Materialization (issue 4)

- `FileMaterialization.materialize` (`FileMaterialization.swift:96–128`):
  **re-issue `requestMaterialization` while still dataless** inside the 120 s
  overall timeout so a stuck provider request is retried without blocking a
  worker on a read fault. Spec 0040 changed the implemented cadence from the
  original post-0038 `~15 s` value to one second and made the returned result
  carry outcome, re-request count, and request-to-completion elapsed time for
  durable attribution.
- `EnrichmentCoordinatorWorkSelection.dequeueDownloadWork`/`nextDownloadID`
  (`:39–72`): **eager (non-viewport) downloads may hold at most
  `downloadConcurrency − 1` slots**; the reserved slot serves only
  viewport-dataless files (observed 39–69 s slot waits behind a full eager
  pool).
- `finishDownload(_:result:)`
  (`EnrichmentCoordinatorCompletion.swift:31–47`): signature takes the full
  `MaterializationResult`; lifecycle fields record the case (`timedOut` vs
  `requestFailed` vs `materialized`), re-request count, request-to-completion
  duration, attempt duration, and byte size (from `EnrichWork.sourceSize`
  captured at `notMaterialized` time). `downloadDispatched` lifecycle phase in
  `dequeueDownloadWork` separates slot wait from transfer time.
- Unchanged: claim leases, eager-materialization policy (ADR 0008/0009),
  enrichment ordering, retry-on-failure loop (it already works — it is what
  saved the two stuck files).

### 3.6 Small review fixes

`enrichmentClaimQuery(claimNotAfter _:)` unused parameter removed
(`CatalogStorePersistence.swift:581–586`). Confirmed clean, untouched:
`duration_seconds` promotion end to end, `RelativeDateText`, schema-reset path.

---

## 4. What deliberately does not change

Reorder cadence (no damping — owner decision). Apply gate semantics. Projection
1 s coalescing cadence. Selection behavior. Sort/filter/query paths. Enrichment
claim ordering and leases. Eager materialization policy beyond the reserved
slot. Schema (nothing persisted by this increment). Thumbnail resolution
(256 px; separate decision). Six-column square layout and 4 pt gutters.

---

## 5. Execution order

1. **WS1 — invariant docs** (§0, all eight files). Nothing else lands first.
2. **WS2 — paint core**: `MediaTileImageCache` + ownership plumbing
   (ViewModel → ContentView → MediaGridView → representable), tile paint
   decision + watchdog + nil-apply guard + tile review fixes. Pure tests.
3. **WS3 — details + preheating**: sticky LRU map, `TilePreheater` +
   `prefetchDataSource`, probe counters.
4. **WS4 — apply semantics**: duration-0 diff was implemented first; spec 0039
   records the post-review fallback to reloadData-class applies after measured
   true-diff cost and updates ADR 0006.
5. **WS5 — overlay geometry** with updated presentation tests.
6. **WS6 — materialization**: re-request loop, reserved slot, outcome/dispatch
   instrumentation. Stub-driven coordinator tests.
7. **WS7 — verification**: `script/verify.sh`; scripted-scroll smoke run
   (`script/smoke-scroll.swift`) against the real 25k OneDrive library with
   capture; acceptance evidence (§6); PR + DoD per AGENTS.md.

Each workstream is independently landable; WS2 alone closes the blocker
(V1–V5 all pass through the tile's single mutation point).

## 6. Acceptance criteria (vs. the 2026-07-05 baseline)

| # | Issue | Criterion | Baseline |
| --- | --- | --- | --- |
| 1 | Flicker (blocker) | Watchdog `MediaTilePaintInvariantViolation` target count **= 0** during a smoke run with active re-enrichment + continuous scrolling; a nonzero count means a same-asset clear attempt was defended and blocked, not proof of visible blanking; capture should show no visible blanking | Blanking every ~3.4 s (153 reloadData applies / 8.6 min) |
| 2 | Text at corners | Scrim + text at 0 px from the thumbnail's top-left corner (layout unit test + screenshot) | 6 pt inset + padding |
| 3 | Scrim width | Darkened area only under text extent (unit test: scrim frame vs text width) | Full content width |
| 4 | Materialization | Stalled-request path costs ≤ ~30 s (re-request), never blocked behind a full eager pool; every download attempt attributable in JSONL (dispatch / slot wait / transfer / outcome case / bytes) | 40 s / 162 s / 193 s, un-attributable 120 s dead polls |
| 5 | Scroll-back placeholders | Previously seen assets repaint with no placeholder frame within cache bounds; scroll-forward mostly pre-painted through the manual batched look-ahead path, with AppKit prefetch treated as opportunistic | Always placeholder-first, 2 async hops |
| — | Responsiveness | Stall count / p50 not worse than 76 / 200 ms; expected better | 76 stalls, p50 200 ms, max 856 ms |
| — | Regressions | Selection, ⌘C copy, sort/filter reset, date/badge text unchanged (existing tests green) | — |

## 7. Test plan

- **Pure**: `paintDecision` table (every row of §3.2 including V3 downgrade and
  V4 nil-apply); overlay frames at 0 px; `overlayVisibility`; LRU merge/evict
  semantics; cache key stability across date/duration-only updates (existing
  `imageContentKey` tests).
- **Coordinator (stubs, existing patterns)**: reserved slot (eager never takes
  the last slot while viewport-dataless pending); re-request cadence
  (stub provider honoring only the Nth request); outcome-case fields.
- **Bridge**: prefetch → sticky-map population; structural apply preserves
  painted content for surviving identities (windowless collection view where
  feasible; otherwise decision-level tests + smoke capture as evidence).
- **Smoke**: scripted scroll on the 25k library; watchdog = 0; §6 timings;
  cache hit-rate and prefetch counters recorded for tuning.

## 8. Risks

- **Duration-0 diff cost at 22.5k** — spec 0039 applies the reloadData fallback
  after live diagnostics reported multi-second true-diff apply spans.
- **Prefetch may not fire in this configuration** — probed; spec 0039 treats
  manual batched look-ahead as primary and AppKit prefetch as opportunistic.
- **Cache memory ceiling** — cost-capped + OS pressure eviction; counters tuned
  once on the smoke run.
- **OneDrive re-request behavior is empirical** — twice-observed; WS6
  instrumentation converts any residual stall from invisible to attributable.
- **Sticky map staleness** — merge keeps rows that deletion later invalidates;
  harmless (cache/map are read-through for rendering; structural applies remove
  deleted identities from the grid, and enrichment updates arrive through the
  same refresh queries as today).
