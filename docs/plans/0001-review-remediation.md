# Plan 0001 — Post-Program Review Remediation

> Non-authoritative plan. Delete when fully done.
> Consolidates every finding from two independent code reviews of the docs/
> instrumentation/refactor program (PRs #62–#71), each verified against the code
> at `main = 886e9f1`. Every fix is decided — there are no open questions.
> "Do the right thing; effort is not a criterion" — so where a choice existed we
> take the correct-architecture option, not the cheap one.

## Finding inventory (all verified against code)

| # | Severity | Finding | Source | Evidence |
| --- | --- | --- | --- | --- |
| F1 | **Blocker** | `main` fails `verify.sh`: `EnrichmentLeaseGatewayTests/priorityClaimInputsFiltersUnavailableAndNonStaleAssets()` fails deterministically | me | test fixture bug; `EnrichmentLeaseGatewayTests.swift:51` |
| F2 | High | Two decoded-image owners (`TileContentStore` + `MediaTileImageCache`); store pins images by count (4096) vs cache cost cap (128 MB/700) → memory blow-up on large libraries | both | `TileContentStore.swift:49`, `MediaTileImageCache.swift:39` |
| F3 | High | No-blank invariant still **defended in the view** (keep-layer branch), not purely in the store | other agent | `MediaAssetTileView.swift:106-116` |
| F4 | Medium | `mergeTileDetails` never pins visible before `evictIfNeeded` → a visible painted entry can be LRU-evicted | other agent | `MediaGridBridge.swift:403-424` |
| F5 | Low | Dead ternary `previous.image == nil ? .detailOnly : .detailOnly` | both | `TileContentStore.swift:104-106` |
| F6 | Medium | Store "decomposition" left `CatalogStore.swift` at 2,548 lines; the ~600-line query surface was never extracted (plan-0007 "under 1,000" unmet) | me | `CatalogStore.swift` |
| F7 | Low | `EnrichmentLeaseGateway` still returns `CatalogStore.StoredAsset` / `CatalogStorePersistence.SQLQuery` — a file-move typed on `CatalogStore`, not a real boundary | other agent | `EnrichmentLeaseGateway.swift:66,98` |
| F8 | Low | Dead code from extraction: `removeRootRuntimeState` guard (both branches identical), `RootRegistry.update` (0 callers), `ScanLeaseController.dequeueNextKnownRoot` (0 callers), `FilesystemReconciler.batchFields` (0 callers) | other agent | `CatalogStore.swift:1039`; `RootRegistry.swift:76`; `ScanLeaseController.swift:157`; `FilesystemReconciler.swift:56` |
| F9 | Medium | Diagnostics log `fields=\(String(describing: fields))` (Swift-dict repr), not flat `key=value` — violates ADR-0015's own grep promise | other agent | 6 sites incl. `CatalogStore.swift:2314`, `UIJankDiagnostics.swift:211` |
| F10 | Low | A main-thread stall logs twice: prose `.error` + structured `.fault op=mainThreadStall` | other agent | `UIJankDiagnostics.swift:152,211` |
| F11 | Low | Comments still say "JSONL" after the sink was removed | other agent | `CatalogProjectionDiagnostics.swift:8`, `UIJankDiagnostics.swift:11`, `MediaGridBridge.swift:26` |
| F12 | Low | AGENTS.md dropped the code-review rubric; plan-0001 §3.6 meant to fold it in and didn't | other agent | `AGENTS.md` (only line 202 survives) |
| F13 | Low | `isTypedBusyError` maps **any** `NSFileWriteUnknownError` to "busy" — too broad, risks false "in use" alerts | other agent | `CatalogWindowViewModelMutation.swift` |
| F14 | Low | Incomplete rename: `MediaAssetCollectionSupport.swift` still grid-level with old prefix | both | `Otos/Views/` |
| F15 | Low | `ARC-003` requirement row has empty `Tested by` (`—`) | me | `docs/requirements.md` |
| F16 | Low | "Always jump to inserted card" re-yanks the user if a card flaps unavailable→available; undocumented consequence | me | `CatalogWindowViewModel.swift:510-527` |

**Not a defect (do not "fix"):** `MediaAssetTileView`/`MediaAssetTilePresentation` keeping the `MediaAsset*` prefix is intentional (per-asset, not grid-level). The other agent's "incomplete rename" note on those is wrong; leave them.

---

## Part 1 — Unblock `main` (F1) · Blocker

**Root cause:** the test's `currentAsset` sets `enrichedSourceMTimeSeconds: 1` but `contentModifiedAt: nil`. `MediaAsset.needsEnrichment` ([CatalogModels.swift:285](../../Otos/Models/CatalogModels.swift)) compares `enrichedSourceMTimeSeconds != mtimeSeconds(contentModifiedAt)` → `1 != nil` → the asset is (correctly) stale, so `priorityClaimInputs` returns both assets and the `count == 1` assertion fails. **Production code is correct; the fixture is wrong.**

**Fix:** in [`OtosTests/EnrichmentLeaseGatewayTests.swift`](../../OtosTests/EnrichmentLeaseGatewayTests.swift) `priorityClaimInputsFiltersUnavailableAndNonStaleAssets`, give `currentAsset` a `contentModifiedAt` whose seconds equal its `enrichedSourceMTimeSeconds`:

```swift
contentModifiedAt: Date(timeIntervalSince1970: 1),   // was nil; now genuinely non-stale
...
enrichedSourceMTimeSeconds: 1
```

Add one guard assertion documenting intent: `#expect(currentAsset.needsEnrichment == false)` before calling `priorityClaimInputs`, so a future fixture drift fails loudly on the cause.

**Acceptance:** `EnrichmentLeaseGatewayTests` green; full `script/verify.sh` green.

This is its own tiny PR, landed first, before anything else.

---

## Part 2 — Grid paint path: one image owner, a pure tile, airtight pinning (F2–F5) · High

The rewrite is directionally right but left two image owners and a view-local invariant guard. Decided design: **`TileContentStore` is the single decoded-image owner, cost-bounded and visible-pinned; `MediaTileImageCache` is deleted; the tile becomes a pure renderer.** This removes the duplication (F2), bounds memory by bytes not count (F2), lets us delete the view-local guard so the invariant is genuinely by-construction (F3), closes the eviction gap (F4), and removes the dead ternary (F5).

### 2.1 `TileContentStore` becomes the sole, cost-bounded image owner

In [`TileContentStore.swift`](../../Otos/Views/TileContentStore.swift):

1. **Add byte-cost accounting.** Track `private var imageBytes: Int` and a `let imageByteBudget: Int` (default `256 * 1024 * 1024`). A decoded image's cost is `image.height * image.bytesPerRow` (fallback `width*height*4`); store it on the `Entry` so eviction can subtract exactly.
2. **Two eviction axes, both pin-aware:**
   - `prune(to liveIDs:)` — unchanged in spirit: drop whole entries whose id ∉ `liveIDs ∪ pinnedIDs`. Subtract their image bytes.
   - **New `enforceImageBudget()`** — while `imageBytes > imageByteBudget`, take the LRU **unpinned** entry that still has an image and set its `image = nil` (keep `detail`+`imageKey`; subtract bytes). Never nils a pinned entry's image. Call it after `applyDecoded` and `mergeDetail`.
   - **Delete the count-based `evictIfNeeded`/`limit`.** Entry *count* is bounded by scope (`prune`) already; images are bounded by cost. Detail entries are cheap.
3. **`applyDecoded`** additionally updates `imageBytes` (subtract old image cost if replacing, add new) and calls `enforceImageBudget()`.
4. **Fix F5:** the dead ternary at line 104-106 becomes `return .detailOnly`.
5. Update the file guide: the store is now the *only* decoded-image owner; images for unpinned entries may be dropped under budget pressure (re-decoded on rebind — the allowed miss path); pinned (visible) images are never dropped.

### 2.2 Delete `MediaTileImageCache`; controller decodes straight into the store

In [`MediaGridBridge.swift`](../../Otos/Views/MediaGridBridge.swift):

1. **Remove the `imageCache` property/parameter** from the view, controller, and `MediaGridBridgeView` wiring; delete `Otos/Views/MediaTileImageCache.swift` and `MediaTileImageCacheTests`.
2. **`seedImageFromCacheIfAvailable` is deleted** — there is no separate cache to seed from. A tile with a known `thumbnailPath` and no image in the store always goes through `startDecode`.
3. **`startDecode`** no longer inserts into a cache; the detached decode carries the `CGImage` to `MainActor` and calls `tileContents.applyDecoded(image, key:, for:)` (as it already does at line 517). Keep the `inFlightDecodes` set — it is the decode-dedup that the cache used to also provide.
4. **Cross-tile reuse of a decode** (rare — one visible tile per id) is served by the store: if two requests want the same id+key, `inFlightDecodes` coalesces the second.

### 2.3 Pin visible IDs on **every** store-mutating path (F4)

Add `pinVisibleIDs()` at the top of `mergeTileDetails` ([line 403](../../Otos/Views/MediaGridBridge.swift)) — matching structural apply and `ensureContentAndMaybeDecode`. With the cost-based image eviction now pin-aware (§2.1) and every mutation pinning first, a visible painted entry's image can never be dropped.

### 2.4 Purify the tile (F3)

In [`MediaAssetTileView.swift`](../../Otos/Views/MediaAssetTileView.swift):

1. **Delete the identity fields** `renderedAssetID` and `renderedImageKey` and the keep-layer branch (lines 106-109). Keep `paintedImagePixelSize` (a real rendering fact used by `layout()`, `hitTestsThumbnailFace`, and placeholder detection) and `renderedBestKind` (placeholder icon).
2. **`render` becomes decision-free:**
   ```swift
   func render(_ content: TileContent?, change: TileContentChange) {
       guard let content else { clearLayerForReuse(); return }
       renderedBestKind = content.detail.bestKind
       configureBadge(for: content.detail)
       if let image = content.image {
           applyImage(image, fade: change == .firstImage || change == .replacedImage)
       } else {
           imageView.layer?.contents = nil
           paintedImagePixelSize = nil
           updatePlaceholderPresentation()
       }
       needsLayout = true
   }
   ```
   This is safe **only because** §2.1–2.3 guarantee a visible painted id always has a non-nil `content.image`; a nil image now means "genuinely never painted for this id" → placeholder is correct. Sequence §2.1–2.3 before this step.
3. Update the tile file guide: the tile holds no asset-identity paint logic; the invariant lives entirely in `TileContentStore`.

### 2.5 Tests (the invariant, proven at the boundary)

- `TileContentStoreTests`: cost eviction drops LRU unpinned images but never pinned; `imageBytes` accounting is exact; detail survives image drop; monotonic rule intact; F5 ternary path returns `.detailOnly`.
- **New `MediaGridPaintInvariantTests`** (the regression both reviews want): drive the controller so that (a) a detail-query merge and (b) a structural recycle of another id cannot nil a painted visible id's layer. Assert on the rendered tile's `paintedImagePixelSize` staying non-nil across those events. This is the test that would have caught F3/F4.

### 2.6 Evidence (hot path — Rob Pike rule 2)

- `script/smoke-run.sh` scroll + enrichment landing; `script/logs.sh show` shows zero placeholder-after-paint for a visible id.
- **Allocations trace** (`script/profile.sh "Allocations"`) on a >5,000-item library, scrolled deep, before/after: peak decoded-image bytes must sit at the store's `imageByteBudget`, not scale with scroll depth. Attach the numbers — this is the F2 proof plan 0005 owed and never delivered.
- Animation Hitches trace on the scroll workload: no regression vs `main`.

**Acceptance:** one image owner (`rg "MediaTileImageCache"` → empty); tile has no `renderedAssetID`/`renderedImageKey`; the new invariant test passes; Allocations shows a cost-bounded image footprint; `verify.sh` green.

---

## Part 3 — Store: delete dead code and finish the decomposition (F6–F8) · Medium

Decided: **finish the one meaningful seam** (extract the query surface) so `CatalogStore` becomes orchestration, and **free the shared types** so the gateways are real boundaries — not stop-and-document. Single-actor rule (`ARC-003`) is preserved throughout: extracted units are pure SQL/mapping helpers the actor calls inside its own isolation, exactly like `EnrichmentLeaseGateway`.

### 3.1 Delete dead code (F8) — do first, its own commit

- `removeRootRuntimeState` ([CatalogStore.swift:1039](../../Otos/Stores/CatalogStore.swift)): both branches call `removeRoot(path:)`; the `rowID` guard is inert. Collapse the whole method to its single call site's `removeRoot(path:)` (inline it and delete the method if it has one caller; otherwise the body becomes just `removeRoot(path:)`).
- Delete `RootRegistry.update` ([RootRegistry.swift:76](../../Otos/Stores/RootRegistry.swift)) — 0 callers.
- Delete `ScanLeaseController.dequeueNextKnownRoot` ([ScanLeaseController.swift:157](../../Otos/Stores/ScanLeaseController.swift)) — 0 callers. (Confirm `startNextScanIfNeeded` doesn't reimplement it inline; if it does, that's fine — it's the live path.)
- Delete `FilesystemReconciler.batchFields` ([FilesystemReconciler.swift:56](../../Otos/Stores/FilesystemReconciler.swift)) — 0 callers.

### 3.2 Free the shared persistence types (F7)

- Promote `CatalogStore.StoredAsset` ([CatalogStore.swift:74](../../Otos/Stores/CatalogStore.swift)) and `CatalogStorePersistence.SQLQuery` ([CatalogStorePersistence.swift:18](../../Otos/Stores/CatalogStorePersistence.swift)) to **top-level `nonisolated` types** in a new `Otos/Stores/CatalogSQLTypes.swift` (`StoredAsset`, `SQLQuery`). Update all references (mechanical). Now `EnrichmentLeaseGateway` and the new query gateway depend on free types, not on `CatalogStore` — a real boundary, not a file move.

### 3.3 Extract the query surface into `CatalogQueryGateway` (F6)

The largest cohesive unextracted unit is the read surface: `orderedAssetIDs` (both overloads), `catalogedAssetCount`, `visibleAssetCount`, `filterOptions`, `mediaAssets`, `mediaTileDetails`, `metadata`, `enrichmentCandidates`, and the `priorityEnrichmentCandidates`/`claimedEnrichmentCandidates` builders plus their `recordSlow*` timers (~600 lines, `CatalogStore.swift:230–693`).

- New `Otos/Stores/CatalogQueryGateway.swift`: **pure functions** that take a `Database` (+ the resolved root-id inputs) and return models/`StoredAsset`s — the SQL string building and `Row`→model mapping only, mirroring `EnrichmentLeaseGateway`.
- `CatalogStore` keeps thin public query methods that resolve root ids from `RootRegistry`, wrap `timedRead`, call the gateway, and record slow-query timings. The actor stays the single DB owner; the gateway never holds a connection.
- Target: `CatalogStore.swift` well under 1,500 lines (orchestration + lifecycle + write paths). We do **not** chase an arbitrary "1,000" — cohesion decides — but the query surface genuinely leaving the file is the point.

### 3.4 Tests

- New `CatalogQueryGatewayTests` and `RootRegistryTests` (the latter was missing — the other agent flagged the absence). Behavior-preserving: the existing `CatalogStoreQueryPlanTests`, `CatalogStoreTests`, `…LifecycleRaceTests` stay green **unmodified** except where re-pointed at a pure gateway function.
- `EnrichmentLeaseGatewayTests` updated for the freed types.

**Acceptance:** dead symbols gone (`rg` each → empty); `StoredAsset`/`SQLQuery` are top-level; query surface lives in `CatalogQueryGateway`; single actor preserved (`rg "^actor " Otos/Stores` → only `CatalogStore`); all store suites green; `verify.sh` green.

---

## Part 4 — Observability hygiene (F9–F11) · Medium

The whole point of ADR-0015 is agent-greppable logs; `String(describing: fields)` breaks it.

1. **Flat fields helper (F9).** Add to `Instrumentation.swift`:
   ```swift
   nonisolated enum OtosLog { … }
   /// Renders ["a":"1","b":"2"] as "a=1 b=2" (sorted, stable) for greppable logs.
   nonisolated func otosLogFields(_ fields: [String: String]) -> String {
       fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
   }
   ```
   Replace `fields=\(String(describing: fields))` at all 6 sites (`CatalogScanner:345`, `EnrichmentCoordinatorCompletion:212`, `UIJankDiagnostics:211`, `CatalogWindowViewModelMutation:361`, `CatalogStore:2141,2314`) with `\(otosLogFields(fields), privacy: .public)` inlined into the message (no `fields=` wrapper — the pairs are the message tail).
2. **Single stall log (F10).** In `recordStall` ([UIJankDiagnostics.swift:148](../../Otos/Support/UIJankDiagnostics.swift)) delete the prose `.error` block; keep only `recordStallDiagnostic`'s `.fault op=mainThreadStall …`, upgraded to carry the flat fields directly (no `String(describing:)`).
3. **Comments (F11).** Update the three "JSONL" comments (`CatalogProjectionDiagnostics.swift:8`, `UIJankDiagnostics.swift:11`, `MediaGridBridge.swift:26`) to describe the current sink: OSLog (`op=`/`key=value`) for the agent; interval signposts for Instruments.

**Acceptance:** `rg "String\(describing:" Otos/ | rg -i "field"` → empty; one log line per stall; no "JSONL" comments remain; `script/logs.sh show` after a run yields lines an agent can `grep 'stallMs=' | grep 'lastOp='`.

---

## Part 5 — Narrow eject busy-detection (F13) · Low

Remove the `NSFileWriteUnknownError → busy` branch in `isTypedBusyError` ([CatalogWindowViewModelMutation.swift](../../Otos/ViewModels/CatalogWindowViewModelMutation.swift)). Busy is proven by typed underlying errors (POSIX `EBUSY`, DiskArbitration dissenter) with the English `"in use"/"busy"` substring as the only fallback; genuinely unknown errors return `.failed(description)` (which surfaces the OS-localized message) rather than a possibly-false "in use" alert. Existing `RemovableEjectOutcomeTests` cases (EBUSY, dissenter, substring fallback, user-cancelled, generic) still pass — none asserts the removed branch. Add one case: an `NSFileWriteUnknownError` with no busy underlying now maps to `.failed`, not `.busy`.

---

## Part 6 — Restore the code-review rubric in AGENTS.md (F12) · Low

Add a `## Code Review` section to [`AGENTS.md`](../../AGENTS.md) (after `## Code Smells`, before `## Toolchain`) capturing the reviewed approach:

- **Two lenses:** (A) implementation fidelity — establish the oracle first (behavior-preserving = existing tests green *unmodified* + runtime differential; bug-fix = reproduce-then-verify; invariant = adversarial "can I construct a violation"), diff-vs-plan, blast-radius, run every agent check, adversarial pass; (B) architecture — is this the simplest correct design, one owner per question, would a blank-slate build arrive here.
- **Independence:** review from the diff not intent; a cold `/code-review` (up to `ultra` for hot-path/store work); invert every "this is fine."
- **Gating:** severity-ranked findings, each a concrete failure scenario + `file:line`; a confirmed correctness bug or a lost invariant/requirement blocks merge; smells and Lens-B notes are logged.

Keep it to ~30 lines — pointers, not a manual.

---

## Part 7 — Small correctness & documentation (F14–F16) · Low

- **F14:** rename `Otos/Views/MediaAssetCollectionSupport.swift` → `MediaGridSupport.swift` (types inside likewise if `MediaAssetCollection`-prefixed and grid-level). Add a one-line note to the file guide that `MediaAssetTile*` intentionally keep the per-asset prefix, so no one "completes" that rename.
- **F15:** fill `ARC-003`'s `Tested by` in [`docs/requirements.md`](../../docs/requirements.md) with the real proof: `Otos/Stores/CatalogStoreTests.swift`, `Otos/…/CatalogStoreLifecycleRaceTests.swift`, `RootRegistryTests.swift`. (`requirements-authority-check.sh` will then verify the paths exist.)
- **F16:** add one line to [`docs/adr/0014-sidebar-selection-and-source-lifecycle.md`](../../docs/adr/0014-sidebar-selection-and-source-lifecycle.md): "always jump to a newly-available card" deliberately re-selects a card that flaps unavailable→available, accepting that it can interrupt a user who has navigated elsewhere — chosen over tracking per-card 'already visited' state. No code change.

---

## Sequencing (each its own PR to `main`, reviewed with the AGENTS.md two-lens gate)

1. **Part 1** — unblock `main`. First, today.
2. **Part 2** — grid paint path (the high-value one). Land as one PR: §2.1→§2.5 in order, with the Part-2.6 evidence attached.
3. **Part 4** — observability hygiene (cheap; makes every later debug greppable).
4. **Part 3** — store: 3.1 dead-code sweep, then 3.2 free types, then 3.3 query-gateway extraction, then 3.4 tests. May be two PRs (cleanup; extraction) if the diff is large.
5. **Part 5, 6, 7** — can ride together as one "cleanup + docs" PR.

Parts are independent except Part 3.3 depends on 3.2, and Part 2.4 depends on 2.1–2.3.

## Definition of Done (whole plan)

- `script/verify.sh` green after every PR (Xcode 27 beta; F1 makes it green to begin with).
- Part 2 Allocations + Hitches traces attached; no-blank invariant test present and passing.
- `rg` acceptance greps in each Part return empty.
- Requirements/ADR updates (F15, F16) landed in the same PRs that touch their areas.
- Each PR carries the full DoD report on the PR **and** sent to the user in full.
- This plan file deleted in the final PR.

## Risks

- **Part 2 is hot-path and visual** — highest risk. Mitigations: `TileContentStore` cost/pin logic is unit-tested before the tile is purified; the tile purification (§2.4) is sequenced *after* pinning is airtight; the new invariant test + Allocations/Hitches traces are the gate; the reloadData structural-apply fallback is untouched.
- **Part 3.3 query extraction** touches many read paths — behavior-preserving, gated by the existing query/plan/race suites staying green unmodified. If any suite needs changing, that is a signal to stop and re-examine, not to edit the test.
- **Single-actor rule** — every extracted unit is a pure helper called inside the actor; no new actor is introduced (grep-guarded in Part 3 acceptance).
