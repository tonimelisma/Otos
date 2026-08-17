# 0093 — Grid Day Headers (DES-069)

Spun off from plan 0092's Increment 7, which anticipated exactly this: "do this
last, and treat it as its own plan if it grows." It has grown — research into
Increment 7 found the real blocker is not the AppKit grid but a missing data path
one layer down, plus an open spec question DES-069 doesn't answer.

**This is a scoping document, not an implementation plan.** It records what's known
so the next pass doesn't have to rediscover it. It does not pick a design for the
new data path or resolve the sort-order question — both need their own review
before an increment list like 0092's can be written.

## Goal

DES-069: "A grid shall be grouped into day sections with a `.headline` date and a
`.subheadline` count, and the current section's header shall pin to the top of the
scroll area while its run scrolls beneath it. Grouping shall be identical for a
library and a removable source."

## What's actually one section today

The plan's own citation for "the grid is currently one section" pointed at
`MediaGridPresentation.swift:41-61`, which is the layout builder
(`makeGridLayout(columnCount:)`) — evidence of a single-section *layout*, not the
real site. The actual single-section assumption is:

- `Otos/Views/MediaGridBridge.swift:126-128` — `enum Section: Hashable { case media }`,
  one case.
- `Otos/Views/MediaGridBridge.swift:480-484` — the grid is
  `NSCollectionViewDiffableDataSource<Section, MediaAssetID>`.
- `Otos/Views/MediaGridStructuralApply.swift:145-152` — `mediaSnapshot(for:)` builds
  every snapshot as `appendSections([.media]); appendItems(orderedIDs, toSection: .media)`.
  This is the real "one flat section" site.
- `OtosTests/MediaGridPaintInvariantTests.swift:106-108` mirrors the same
  construction in test harness code — a second call site to update.

Swapping `Section` from one case to a `Hashable` day-bucket key and building
multi-section snapshots is bounded and mechanical — two production files plus the
test harness. **This part is not the hard part.**

## The real blocker: no per-asset date reaches the grid's data path

Checked every layer between the SQL query and the AppKit tile:

- `Otos/Stores/CatalogQueryGateway.swift` — `orderPlan` sorts by `best_capture_unix`
  in SQL, but the fetch functions (`fetchOrderedAssetIDRows`, `fetchAssetIDs`) select
  only `library_root_id, relative_path`. No date column reaches Swift.
- `Otos/Models/CatalogModels.swift` — `CatalogMediaGridState` carries
  `orderedAssetIDs: [MediaAssetID]` and a `detailRefreshGeneration` scalar. No date
  field. The comment directly above it states the design intent explicitly:
  publishing window state never copies every asset's values — only the visible
  window is faulted in, by design, to stay cheap at 20k+ scale.
- `MediaTileDetail` (also `CatalogModels.swift`), fetched only for the visible
  window via `MediaTileDetailReader`, likewise carries no date field.

`NSCollectionViewDiffableDataSource` needs section membership for the whole list up
front to build a snapshot — day boundaries can't be computed from the visible window
alone. Getting whole-list dates therefore means either:

- a new bulk query returning `(MediaAssetID, dayBucket)` for the entire ordered list,
  separate from the windowed per-asset detail fetch, or
- some other way to derive section boundaries from what's already computed (the SQL
  sort already walks assets in date order — worth asking whether the *boundaries*
  alone, not full dates, could be produced more cheaply than a value per asset).

Both are new store/query-layer work, and both mean deliberately widening a
documented scale principle (window state stays windowed). That is a real
architecture decision — it belongs in an ADR revision or a new ADR, decided before
implementation starts, not folded into a grid PR.

## Open spec gap: sort order

Day-section grouping only makes sense when assets are date-contiguous, i.e. under
`.bestDate` sort (`Otos/Models/CatalogQueryModels.swift` — `MediaSortOrder` also
supports `.name` and `.size`, either direction). DES-069 doesn't say what headers do
under name/size sort, where a "day" isn't a contiguous run. Needs a design decision
— a single dateless section, no headers under those sorts, or something else — before
implementation, not an implementer's guess.

## Invariant risk

- `Otos/Views/TileContentStore.swift` — the no-blank enforcement point (APP-015,
  ADR 0006) is keyed by `MediaAssetID`, not `IndexPath` or section. Structurally this
  looks insulated from section changes: a tile keyed the same way resolves to the
  same store entry regardless of which section it's in now.
- The real risk is in `MediaGridStructuralApplyPolicy` (`MediaGridSupport.swift`) and
  `applyStructure` (`MediaGridStructuralApply.swift`), which classify a structural
  change (reorder-only vs. large-apply vs. animate) entirely from a flat
  `[MediaAssetID]` diff. Section insert/remove — a new day appearing at the top as
  time passes, or an asset's day changing because enrichment corrected its capture
  date — is a new class of change this policy has no concept of today. Getting the
  classification wrong risks either flicker (animating a large restructure) or
  falling back to `reloadData` more than intended, which ADR 0006 explicitly warns
  is not something no-blank correctness should lean on.
- `MediaGridMutationGate.swift` retains `displayedOrderedIDs` as flat state; likely
  fine to leave flat (section is derivable from date), but needs re-verification
  once sections exist.
- New test coverage needed before this ships: an asset's day changing under
  enrichment while sections are already built; a day boundary appearing/disappearing
  at the scroll edge; both under Reduce Motion.

## AppKit layer, once the data problem is solved

Assuming per-asset day buckets exist for the whole list, the AppKit-side work looks
bounded and lower-risk by comparison:

- `MediaGridPresentation.swift` (`makeGridLayout`) — add pinned
  `boundarySupplementaryItems` to the section.
- `MediaGridBridge.swift` — register a supplementary header view, set
  `dataSource.supplementaryViewProvider` (currently unset).
- `MediaGridAnimatedLayout.swift`, `MediaGridZoomPolicy.swift`,
  `MediaGridSelectionController.swift` — all operate on `IndexPath`/asset identity in
  ways that look section-count-agnostic; re-verify once headers exist, especially
  animated insert/remove during section churn (untested territory today).
- `GridColumnCount.swift`, `MediaGridLayoutFactory.swift` — no coupling, no changes
  expected.

## Before writing an implementation plan

1. Decide the date-plumbing design (new bulk query vs. an alternative) and record it
   in an ADR — revising 0006 or adding a new one.
2. Resolve the name/size-sort question with whoever owns the design system.
3. Write the day-boundary-under-enrichment and section-churn-under-Reduce-Motion test
   cases *before* implementation, per ADR 0006's own standard for this code.

Only then does a numbered increment list like 0092's make sense here.
