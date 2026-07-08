# Plan 0004 — Small Cleanups

> Non-authoritative plan. Delete when done.
> Execution order: **fourth** — cheap hygiene between the instrumentation
> consolidation and the larger refactors. Everything here is low-risk and
> mechanical; none of it changes behavior.

## 1. Merge the two selection namespaces

**Current state:** the pure selection *model* is `GridSelection`
([Otos/Views/GridSelection.swift](../../Otos/Views/GridSelection.swift));
a second enum `MediaGridSelection`
([Otos/Views/MediaGridSelection.swift](../../Otos/Views/MediaGridSelection.swift))
still holds two surviving helpers plus the clipboard writer:

- `MediaGridSelection.selectionDelta(current:target:)` — used by
  `applySelectionDelta` ([MediaAssetCollectionSelection.swift:115](../../Otos/Views/MediaAssetCollectionSelection.swift))
- `MediaGridSelection.orderedSelection(_:in:)` — used by `copy(_:)`
  ([MediaAssetCollectionSelection.swift:145](../../Otos/Views/MediaAssetCollectionSelection.swift))
- `MediaGridClipboard` (same file) — keep as-is, it is a distinct concern.

**Change:**
1. Move `selectionDelta` and `orderedSelection` into `GridSelection` as
   static helpers (they are selection math; one home).
2. Delete the `MediaGridSelection` enum. Move `MediaGridClipboard` into its
   own `MediaGridClipboard.swift` (with its existing guide comment).
3. Update the two call sites + `OtosTests/MediaGridSelectionTests.swift`
   (rename to `GridSelectionHelperTests` or fold the cases into
   `GridSelectionTests.swift` — prefer folding; the file is small).

**Acceptance:** `rg "MediaGridSelection"` → only clipboard file history;
tests green.

## 2. Comment hygiene in the new selection code

- [GridSelection.swift:65](../../Otos/Views/GridSelection.swift): the doc
  comment says "⌘⇧-click **(eng default)**" — increment-planning language in
  a file guide. Replace with the actual rationale: "extends the range while
  keeping existing islands (differs from plain ⇧, which recomputes from the
  base)".
- [MediaGridCollectionView.swift:36](../../Otos/Views/MediaGridCollectionView.swift):
  the `{ // swiftlint:disable:this opening_brace` workaround. Restructure the
  condition so the disable comment disappears, e.g. hoist the body into a
  helper: `if let candidate = hit, !clickHitsThumbnailFace(candidate, event) { hit = nil }`
  with a private func doing the item/tileView casts.

## 3. Naming: reduce `MediaAssetCollection*` / `Catalog*` prefix noise

The Views folder currently reads:
`MediaAssetCollectionView / …Item / …Selection / …StructuralApply / …Zoom /
…Prefetch / …Layout / …Support`, plus `MediaGrid*` types. Two prefixes for one
feature area tax every read; folders already namespace.

**Decision needed from the owner before executing (rename churn is real):**
adopt the `MediaGrid` prefix everywhere in the grid boundary (it is already
the newer convention: `MediaGridCollectionView`, `MediaGridMutationGate`,
`MediaGridAnimation`…), renaming:

| Current | New |
| --- | --- |
| `MediaAssetCollectionView.swift` (representable + controller) | `MediaGridBridge.swift` (`MediaGridBridgeView`, `MediaGridViewController`) |
| `MediaAssetCollectionItem` | `MediaGridItem` |
| `MediaAssetCollectionSelection.swift` | `MediaGridSelectionController.swift` (extension file) |
| `MediaAssetCollectionStructuralApply.swift` | `MediaGridStructuralApply.swift` |
| `MediaAssetCollectionZoom.swift` | `MediaGridZoom.swift` |
| `MediaAssetCollectionPrefetch.swift` | `MediaGridPrefetch.swift` |
| `MediaAssetCollectionLayout.swift` | `MediaGridLayoutFactory.swift` |

Pure rename (Xcode refactor or sed + verify), one PR, no logic changes.
Tile-level types (`MediaAssetTileView`, `MediaAssetTilePresentation`) keep
their names — they are per-asset, not grid-level. If the owner declines, drop
this item; items 1–2 and 4–5 stand alone.

## 4. Re-merge artificial ViewModel file splits (post plan 0001)

Once size lints are warnings, fold back the splits that existed only for the
old 500-line error:
- `CatalogWindowViewModelQuery.swift` → into `CatalogWindowViewModel.swift`
  (restores `private(set)`-adjacent intent definitions in one place).
- `CatalogWindowViewModelSidebarPolicy.swift` → same.
- Keep `…Mutation.swift`, `…SourceMonitoring.swift` — those are cohesive
  domains, not lint splits. (`…GridTelemetry.swift` is deleted by plan 0003.)

Update the file-guide comments that currently explain the split
("keeps the main ViewModel file within the repo file-length budget").

## 5. Delete the stale `CatalogProjection.windowState(...)` helper if unused

[CatalogProjection.swift:94-108](../../Otos/Services/CatalogProjection.swift)
constructs a one-off window state with `generation: 0`. Verify with
`rg "\.windowState\("` — if only tests use it, move it into the test target's
support file; if nothing uses it, delete it.

## 6. Acceptance criteria

- `verify.sh` green after each item; zero behavior diffs (renames + moves
  only).
- No `swiftlint:disable` remains in `MediaGridCollectionView.swift`.
- Requirements rows' "Implemented in" paths updated for every rename
  (`script/requirements-authority-check.sh` will catch misses once plan 0001
  lands — run it).
