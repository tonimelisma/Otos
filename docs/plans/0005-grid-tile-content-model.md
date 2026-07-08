# Plan 0005 — Grid Tile Content Model: Make the No-Blank Invariant Structural

> Non-authoritative plan. Delete when done.
> Execution order: **fifth** — the biggest grid-side change; after the small
> cleanups, before the store work (independent of it). This generalizes the
> lesson of the selection fix (PR #57): **own the state, render it into
> AppKit; never read-and-correct AppKit mid-flight.**
>
> ⚠️ The no-blank-grid invariant is an owner-declared absolute. This plan's
> entire purpose is to make it *unrepresentable* instead of *defended*; any
> step that cannot demonstrably preserve it stops the work.

## 1. Problem

The tile paint path *defends* the invariant with a watchdog instead of making
violations impossible. Current machinery (verified):

- `TilePaintDecision` (4 cases) + `paintDecision(_:)`
  ([MediaAssetTilePresentation.swift:94-186](../../Otos/Views/MediaAssetTilePresentation.swift))
  decides per configure: `paintCached / keepCurrent / loadAsync(retainsCurrentImage:) / placeholder`.
- The tile carries five pieces of mutable identity state
  (`currentImageContentKey`, `currentAssetID`, `currentImagePixelSize`,
  `currentBestKind`, `loadGeneration`) that must stay mutually consistent
  ([MediaAssetTileView.swift:36-44](../../Otos/Views/MediaAssetTileView.swift)).
- `clearPaintedImage(for:reason:enforcesInvariant:)` is a **runtime watchdog**:
  if a code path attempts to blank a painted same-asset tile it logs
  `MediaTilePaintInvariantViolation` and refuses
  ([MediaAssetTileView.swift:327-344](../../Otos/Views/MediaAssetTileView.swift)).
  A watchdog for one's own invariant means the invariant is being fought,
  not enforced by construction.
- Async decode completions re-validate three fields (`loadGeneration`,
  `currentAssetID`, `currentImageContentKey`) before applying — the
  stale-completion problem solved per-tile, ad hoc.
- The controller separately keeps `MediaTileDetailCache` (sticky details) and
  `MediaTileImageCache` (decoded images) — the *data* needed to always paint
  exists, but the tile does not treat it as its source of truth; it treats its
  own last-applied layer contents as truth and guards transitions.

## 2. Target design

**One owner: a controller-held `TileContentStore` mapping
`MediaAssetID → TileContent`. A tile renders `TileContent` idempotently and
holds no identity logic of its own.**

```swift
/// Controller-owned, MainActor. The single source of truth for what any tile
/// showing `id` must display. Monotonic per asset: `image` only ever advances
/// to a newer decode for the same asset; it never regresses to nil.
nonisolated struct TileContent: Equatable {
    var detail: MediaTileDetail          // badge, kind, thumbnail path, stamps
    var imageKey: String                  // MediaAssetTilePresentation.imageContentKey(detail)
    var image: CGImage?                   // best decoded image known for this asset
}

@MainActor final class TileContentStore {
    private(set) var contents: [MediaAssetID: TileContent]
    func mergeDetail(_ detail: MediaTileDetail, for id: MediaAssetID) -> TileContentChange
    func applyDecoded(_ image: CGImage, key: String, for id: MediaAssetID) -> TileContentChange
    func prune(to liveIDs: Set<MediaAssetID>)   // structural applies; bounded like MediaTileDetailCache
}
```

- **The monotonic rule lives in one place**: `mergeDetail` never clears
  `image`; a detail whose `imageContentKey` differs marks the image *stale*
  (keeps showing it) and the caller starts a decode; `applyDecoded` replaces
  the image only when `key` matches the store's current key for that asset —
  the stale-completion check moves from tile fields into the store.
- **Tile becomes ~pure rendering**:
  `func render(_ content: TileContent?, animatedFirstPaint: Bool)` — paints
  `content.image` if present, else the placeholder. `prepareForReuse` just
  clears the layer; the next `render` repaints from the store. There is no
  code path that clears a painted image while an asset stays on screen,
  because rendering always goes through the store's monotonic value —
  **the invariant holds by construction and the watchdog is deleted.**
- **Fade decision** stays: first paint for an asset in this process
  (`store` had `image == nil` before this apply) fades; repaint of an
  existing image is instant. The store returns that as part of
  `TileContentChange` (`.firstImage`, `.replacedImage`, `.detailOnly`,
  `.unchanged`) so the tile does not re-derive it.
- **Decode pipeline**: the controller (not the tile) owns decode tasks keyed
  by `(id, imageKey)`, off-main decode as today
  (`MediaAssetTilePresentation.loadImage`), inserting into
  `MediaTileImageCache` and then `store.applyDecoded`. Per-tile
  `loadGeneration` disappears; duplicate-decode suppression is a controller
  set of in-flight keys (the preheat path already merges into the same
  `MediaTileImageCache`, unchanged).
- **Memory bound**: `TileContent.image` references the same `CGImage`s as
  `MediaTileImageCache`; the store is pruned with the same bounded policy as
  `MediaTileDetailCache` today (LRU cap), *except* IDs currently visible are
  never evicted. On re-bind after eviction, the flow equals today's
  cache-miss path (placeholder-until-decode is allowed only if that asset's
  image was evicted while off-screen — same as current behavior after
  `reloadData` recycling, which the invariant already permits only when the
  cache still holds the image; verify: `MediaTileImageCache` cost/count
  limits vs. `TileContentStore` cap must be aligned so a visible-set image is
  never evicted from the byte cache while pinned in the store).

## 3. What gets deleted

- `TilePaintDecision`, `paintDecision(_:)`, `TilePaintRequest`,
  `TilePaintContext` (keep `imageContentKey` and `contentRect`/face geometry).
- `clearPaintedImage(...enforcesInvariant:)` and the watchdog event/log
  (`MediaTilePaintInvariantViolation`; the `GridTelemetry.recordWatchdog`
  call is already gone via plan 0003).
- Tile fields `currentImageContentKey/currentAssetID/currentImagePixelSize/
  loadGeneration` and `loadTask` (pixel size moves into render-from-content:
  the aspect-fit face comes from `content.image` dimensions or nil).
- The `retainsCurrentImage` threading.
- `MediaTileDetailCache` merges into `TileContentStore` (it is the same
  concept minus the image field) — one sticky store instead of two.

Unchanged: `MediaGridMutationGate`, structural apply + reloadData fallback
policy (byte-identical branch), `GridSelection`, preheat look-ahead,
`MediaTileImageCache` as the decode byte cache, hit-test face geometry.

## 4. Step-by-step

1. **Write `TileContentStore` + `TileContentChange` with exhaustive unit
   tests first** — the monotonic rule, stale-completion rejection, prune
   semantics, first-paint vs repaint classification. This is the new
   invariant carrier; it must be airtight before any UI change.
2. Introduce the store into the controller alongside the old path (fed by the
   same detail merges), dark — assert in DEBUG that old-path decisions and
   store-derived renders agree on visible tiles (one temporary log line).
   Run `script/smoke-run.sh`; compare.
3. Swap `configure`/`reconfigureVisibleItems`/data-source item creation to
   `render(store.contents[id])`; move decode ownership to the controller;
   delete the old tile fields and decision enum.
4. Delete watchdog paths; update the file guides
   (`MediaAssetTileView.swift`, `MediaAssetCollectionView.swift`) — they
   currently *explain* the defended invariant and must now explain the
   structural one.
5. Update tests: `MediaAssetTilePresentationTests` paint-decision cases
   migrate to `TileContentStore` tests; tile tests assert observable state
   (image layer content non-nil across detail downgrades, badge updates,
   reuse+rebind).
6. Evidence: smoke run with scroll churn + enrichment landing
  (`script/smoke-run.sh`), `script/logs.sh show` demonstrating zero
  `paintWatchdog`-class errors (the log line itself is gone — instead grep
  that no tile ever logs a first-paint fade for an asset that already had
  `.replacedImage`/`.unchanged` earlier in the session; add a temporary
  `.debug` assertion log if needed), plus an Animation Hitches trace via
  `script/profile.sh` on the scroll workload (this is a hot path; Rule 2).

## 5. Acceptance criteria

- All rows of the current no-blank behavior preserved (requirement APP-015
  family): reorder-only applies, detail-query failures, nil loads, scrolling,
  enrichment, structural applies, availability churn never blank a painted
  same-asset thumbnail — now with **no** runtime guard needed.
- `rg "enforcesInvariant|TilePaintDecision|loadGeneration" Otos/` → empty.
- Tile view LOC drops materially (~470 → target under ~300) and holds no
  asset-identity fields.
- Smoke + hitch-trace evidence attached; `verify.sh` green.
- The `no-blank-grid-invariant` requirement row's "Implemented in" points at
  `TileContentStore`.

## 6. Risks

- **Highest-risk plan in the set** (hot path, visual). Mitigations: store
  unit-tested first; dark-run comparison step; smoke + trace evidence; the
  reloadData fallback branch is untouched.
- **Memory growth**: pinning visible images + sticky store. Mitigation: same
  caps as today's two caches; measure with the Allocations template on a
  large library before/after (attach numbers).
- **Fade regressions** (double-fade or missing fade): covered by
  `TileContentChange` classification tests + by-eye check on a cold launch
  (owner-run, non-blocking).
