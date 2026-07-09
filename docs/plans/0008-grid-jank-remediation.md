# Plan 0008: Grid Jank Remediation (Animated Small-Delta Reorders, Dequeue-Pass Pinning, Placeholder Churn)

Status: active. Rebased 2026-07-09 onto `main` @ 427739b (PR #78). Delete this
file when all parts have landed on `main`.

Owner evidence: `docs/research/grid-reorder-cadence-and-appkit-diffable-apply.md`
(instrumented run 2026-07-09; trace
`build/Profiles/SwiftUI-jank-20260709-114428.trace`, log
`logs/run-20260709T184420Z-p77645-prod.log`; fresh diffable-apply benchmark in
the "Spike results" section; harness `script/poc-diffable-apply-bench.swift`).

## What already landed in PR #78 (do not redo)

PR #78 (`fix: coalesce scroll work and pin visible IDs once per pass`) shipped:

- Scroll-bounds coalescing on a ~16 ms trailing edge; unchanged visible-ID
  lists skip the detail query (`lastDetailQueryIDs` /
  `wouldStartVisibleDetailQuery`).
- `reconfigureVisibleItems` pins the visible set **once per pass**
  (MediaGridBridge.swift:464) and `ensureContentAndMaybeDecode` no longer pins
  at all (callers own pinning — see its doc comment,
  MediaGridBridge.swift:579).
- Rich diagnostics this plan's verification relies on:
  `op=ui.mediaGrid.reconfigure` (pinMs/ensureMs/renderMs/decode counters),
  `op=ui.mediaGrid.scrollBounds` (per-second tick/flush/skip window), and the
  structural-apply breakdown `diffPolicyMs`/`snapshotBuildMs`/`applyCallMs`/
  `completionMs` on `op=ui.mediaGrid.structuralApply`.
- ADR 0006 / ARC-023 updated with an in-app measurement: at ~23k, the
  reloadData-class apply and a zero-duration true-diff both land in a
  ~110–250 ms `applyMs` ballpark — confirming this plan's premise that
  true-diff is not pathologically slow. (`applyMs` folds in completion work and
  the still-present dequeue-pass pin storm below; the harness isolates the
  bare apply call at ~23–33 ms for small move counts.)

## Problem, in one paragraph (post-#78)

While background enrichment runs (~4.8k of 23k assets done at diagnosis — the
storm recurs every session for hours), each 1–3-asset enrichment flush changes
`best_capture_unix` values, which reorders the `bestDate:descending` list.
Projection publishes the new order on its 1-second cadence (~18 identity-changed
publications/minute observed), and each one drives a structural apply through
AppKit's reloadData-class path (`animatingDifferences: false`), which tears down
and recreates every visible item. Each recreated item's dequeue still recomputes
and re-pins the whole visible set (`makeCollectionItem` →
`pinVisibleIDs()`, MediaGridBridge.swift:336) — ~90 × O(visible) on exactly the
jank path — and placeholder tiles still allocate a fresh
`NSImage(systemSymbolName:)` on every layout pass. Baseline (pre-#78 capture):
11 main-thread hangs of 266–510 ms in 55 s of scrolling, all tagged
`MediaGridViewController.applyStructure`.

## Owner constraints (2026-07-09, explicit)

- **The once-per-second reorder cadence stays.** Fix the jank; do not make it
  rarer. (A slower-cadence "holdback" proposal was rejected.)
- **Reorders should animate** — the 1–3-thumbnail trickle is the case that
  matters; whole-list reorders do not need animation.
- The spec-0039-era apply-cost measurement was declared stale and is gone from
  the docs. Only the fresh 2026-07-09 numbers (research doc + #78's in-app
  measurement) may be cited.

## Why the fix works (fresh measurements, 2026-07-09)

Bench harness (`script/poc-diffable-apply-bench.swift`, results table in the
research doc): `apply(_:animatingDifferences: true)` at n = 23,043 with
realistic two-string identifiers costs **~23–28 ms call-to-return for K = 1–3
moved items** (33 ms at K = 200, ~10 ms floor at K = 0), with a quadratic cliff
in moved-item count (~88 ms at K = 1,000, ~1 s at K = 5,000, ~30 s at full
reversal). #78's in-app measurement agrees directionally (both paths
~110–250 ms `applyMs`, which includes completion work and the dequeue-pass pin
storm). The animated path additionally **moves items instead of recreating
them**, so the ~90-item teardown/rebind — the actual jank driver — disappears
for the trickle case, and the moves animate, which is the owner's preference.
Whole-list reorders must keep the unanimated path (cliff). After Parts A/C the
in-app `applyCallMs` field is the arbiter; expect it near the harness numbers.

## Invariants that every part must preserve

- **APP-015 no-blank invariant**: a painted same-asset thumbnail never regresses
  to placeholder content. It is structural in `TileContentStore` (pinned visible
  images are never dropped). `OtosTests/MediaGridPaintInvariantTests.swift` and
  `OtosTests/TileContentStoreTests.swift` stay green **unmodified**.
- **One implementation path**: background updates and user intents keep flowing
  `CatalogProjection` → `CatalogWindowViewModel` →
  `MediaGridBridgeView.updateNSViewController` → `MediaGridMutationGate` →
  controller. No new side channels, no cadence policy outside the projection.
- **Selection preservation** across same-descriptor applies (APP-010/011):
  `MediaGridBridgeTests`/`GridSelectionTests` green; a surviving tile's
  selection ring must not blink on a background apply (animated moves do not
  recycle surviving items, so this gets easier, not harder).
- Main-actor work stays well below the 100 ms hang threshold; every part ships
  with before/after log or trace evidence.

## Part A (residual) — O(1) pinning on the dequeue path

**Files:** [Otos/Views/MediaGridBridge.swift](../../Otos/Views/MediaGridBridge.swift),
[Otos/Views/TileContentStore.swift](../../Otos/Views/TileContentStore.swift)

**Why:** #78 fixed the reconfigure pass but moved the whole-set pin into
`makeCollectionItem` (MediaGridBridge.swift:336) — once **per dequeued item**.
Scroll dequeues arrive one or a few per tick (fine), but a reloadData-class
structural apply recreates all ~90 visible items in one pass → ~90 ×
(`indexPathsForVisibleItems()` + sort + Set build + `pinVisible`) on exactly
the path that already hangs. Part C removes most reloadData applies for the
trickle case, but descriptor changes and membership changes keep that path, and
scroll-time dequeues benefit too.

**Contract:** whole-set `pinVisible(_:)` happens once per pass boundary
(reconfigure :464, merge :553, structural-apply completion
MediaGridStructuralApply.swift:147 — all already correct); an individual bind
additively pins only its own id in O(1).

Steps:

1. In `TileContentStore`, add an additive pin next to `pinVisible(_:)`:

   ```swift
   /// Additively pins one id (a tile being bound mid-pass). `pinVisible(_:)`
   /// replaces the whole set at the next pass boundary.
   func pin(_ id: MediaAssetID) {
       pinnedIDs.insert(id)
   }
   ```

   Update the file guide comment: pinning has two shapes — whole-set
   replacement at pass boundaries, additive single-id during binds.

2. In `makeCollectionItem` (MediaGridBridge.swift:325), replace the
   `pinVisibleIDs()` call at :336 with `tileContents.pin(assetID)`. The
   ensure/render calls below it stay unchanged
   (`ensureContentAndMaybeDecode`'s doc comment already says callers own
   pinning — extend it to name the additive form for dequeues).

3. Leave every other `pinVisibleIDs()` / `pinVisible` call site as #78 shaped
   them (once per pass). Do not try to share `visibleAssetIDs()` computations
   across different event sources.

**Oracle:** behavior-preserving; all existing tests green **unmodified**
(including #78's new `lastReconfigurePinCallCount` assertions). New tests in
`OtosTests/TileContentStoreTests.swift`:

- `pin(_:)` keeps that id's image safe from `enforceImageBudget()` eviction and
  `prune(to:)`.
- A subsequent `pinVisible(_:)` without the id makes it evictable again
  (replacement semantics unchanged).

Adversarial scenario to keep true (encode in `MediaGridBridgeTests` if
representable): during a reloadData-class apply, AppKit binds items via
`makeCollectionItem` *before* the completion re-pins the visible set; with the
additive pin each bound tile is pinned at bind time, so a decode landing
mid-apply cannot be budget-evicted — the same guarantee #78's per-item
whole-set pin provides, at O(1) per bind.

**Evidence to attach:** `op=ui.mediaGrid.reconfigure` pinMs before/after, and
`op=ui.mediaGrid.structuralApply` `applyCallMs`/`completionMs` before/after on
the capture protocol below.

## Part B — Cache placeholder SF Symbol images; stop re-assigning per layout

**Files:** [Otos/Views/MediaAssetTileView.swift](../../Otos/Views/MediaAssetTileView.swift),
[Otos/Views/MediaAssetTilePresentation.swift](../../Otos/Views/MediaAssetTilePresentation.swift)
(both untouched by #78; anchors current)

**Why:** `updatePlaceholderPresentation()` (MediaAssetTileView.swift:232) runs
on every `layout()` pass of every tile and, for placeholder tiles, allocates
`NSImage(systemSymbolName:)` every time (MediaAssetTileView.swift:241). With
~79 % of the library unenriched, that measured 2.8 s of main-thread time
(1.6 s inside the NSImage initializer) in 55 s. The AppKit header documents the
initializer as creating a new image per call; there are exactly two icons
(photo, film), so cache them once.

Steps:

1. In `MediaAssetTilePresentation` (which already owns
   `placeholderIconSystemName(for:)`), add a `@MainActor` cached accessor:

   ```swift
   @MainActor
   static func placeholderIcon(for kind: MediaKind?) -> NSImage? {
       let name = placeholderIconSystemName(for: kind)
       if let cached = placeholderIconCache[name] { return cached }
       let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
       placeholderIconCache[name] = image
       return image
   }
   @MainActor
   private static var placeholderIconCache: [String: NSImage?] = [:]
   ```

   (Tiles are `@MainActor` AppKit views; keep the cache main-actor-confined —
   no locks.)

2. In `MediaAssetTileView`, track the last-applied icon name and only assign
   when it changes:

   ```swift
   private var appliedPlaceholderIconName: String?
   ```

   In `updatePlaceholderPresentation()`:
   - compute `isPlaceholder` as today;
   - when placeholder: resolve the icon name, and only if it differs from
     `appliedPlaceholderIconName`, assign
     `placeholderIconView.image = MediaAssetTilePresentation.placeholderIcon(for: renderedBestKind)`
     and record the name. Keep the frame assignment every layout (bounds change
     with zoom).
   - reset `appliedPlaceholderIconName = nil` in `clearLayerForReuse()` so a
     recycled tile re-applies.

3. Optionally route the film-badge icon (MediaAssetTileView.swift:72) through
   the same accessor; it is init-time-only today, so this is polish.

**Oracle:** behavior-preserving; all existing tile/presentation tests green
unmodified. Add to `OtosTests/MediaAssetTilePresentationTests.swift`: the
cached accessor returns the **same instance** for repeated calls with the same
kind, and photo/film kinds return distinct instances.

## Part C — Animate same-descriptor reorder-only applies (the jank fix)

**Files:** [Otos/Views/MediaGridSupport.swift](../../Otos/Views/MediaGridSupport.swift),
[Otos/Views/MediaGridStructuralApply.swift](../../Otos/Views/MediaGridStructuralApply.swift),
[Otos/Views/MediaGridMutationGate.swift](../../Otos/Views/MediaGridMutationGate.swift),
[Otos/Views/MediaGridBridge.swift](../../Otos/Views/MediaGridBridge.swift),
[Otos/Views/MediaGridAnimatedLayout.swift](../../Otos/Views/MediaGridAnimatedLayout.swift);
docs: ADR 0006, ADR 0011 (one consequence line), `docs/requirements.md`
(ARC-023, APP-006).

**Behavior specification (this wording goes into ADR 0006 and the rows):**

- A structural apply whose identities are a **same-membership reorder under an
  unchanged descriptor** (the enrichment trickle) applies with
  `animatingDifferences: true` inside the existing tuned
  `NSAnimationContext` group — moved tiles animate to their new positions;
  surviving items are not recycled.
- Descriptor-changed applies (scope/sort/filter — including whole-list sort
  flips) and large membership changes keep today's unanimated reloadData-class
  path. Rationale: the animated diff's cost is quadratic in moved items
  (research doc table); descriptor changes reset scroll anyway, so animation
  has no value there.
- Small insert/remove applies keep their existing spec-0047 animated behavior,
  unchanged.

Steps:

1. **Give the policy the descriptor fact.** In `MediaGridMutationGate`, the
   `.apply` action carries `resetScroll`/`resetSelection`, both set from
   `descriptorChanged` (see `idleGridAction`). Extend the action to carry the
   fact explicitly — `.apply(CatalogMediaGridState, descriptorChanged: Bool)` —
   and derive `resetScroll = resetSelection = descriptorChanged` in the
   executor (`perform(_:)` in MediaGridBridge.swift). Update
   `MediaGridBridgeTests` gate assertions accordingly (this part is
   behavior-changing; test edits are expected and reviewed).

2. **Policy change.** `MediaGridStructuralApplyPolicy.summarize`
   (MediaGridSupport.swift:43) gains a `descriptorChanged: Bool` parameter.
   Intent, as a truth table (encode in tests, step 5):
   - same-descriptor, same-membership reorder → `animatingDifferences: true`
     (NEW — the trickle case, any n);
   - descriptor-changed reorder (sort flip) → reloadData fallback (as today);
   - large insert/remove (`n ≥ 1000`) → reloadData fallback (as today);
   - small insert/remove → animated (as today, spec 0047).

3. **Apply branch.** `applySnapshot(_:summary:completion:)`
   (MediaGridStructuralApply.swift:109; fallback guard at :114) already routes
   `summary.animatingDifferences == true` through the `NSAnimationContext`
   group with `MediaGridAnimation.applyDuration`. No change needed beyond the
   policy — but update the branch's doc comment (it currently describes the
   `false` branch as the path for *all* large/reorder applies and cites the
   ~110–250 ms ballpark; scope it to descriptor-change/membership applies and
   refresh the numbers per the verification evidence).

4. **Animated layout non-interference.** `MediaGridAnimatedLayout` decorates
   only the index paths a given apply batch inserted or deleted. Verify (and
   lock in with a test in `OtosTests/MediaGridAnimatedLayoutTests.swift`) that
   a move-only batch registers **no** decorated index paths, so moved items get
   `super`'s unmodified attributes and animate as plain position changes.

5. **Tests.**
   - Policy truth table in `MediaGridBridgeTests` (or a dedicated policy test
     file): every row of step 2, including `n ≥ 1000` same-descriptor reorder →
     `animatingDifferences == true` (the 23k trickle case), and sort-flip
     reorder → fallback.
   - Gate action shape change (step 1).
   - Paint-invariant and selection tests stay green **unmodified** (APP-015,
     APP-010/011).

6. **In-app completion gate (hard requirement before merge).** The benchmark
   could not observe the `completion:` handler firing for
   `animatingDifferences: true` in a bare CLI harness (research doc caveat),
   while production animated insert/remove applies demonstrably complete. The
   mutation gate frees `inFlight` only from the completion, so if move-only
   animated applies never completed, the grid would stop applying (newest state
   parks forever — #78's `pendingGrid=true` stall field would show it).
   Verification: run the capture protocol and confirm
   `op=ui.mediaGrid.structuralApply phase=finish` lines continue at the
   enrichment cadence (they are logged from the completion path) with sane
   `applyCallMs`/`completionMs`. If completions do not fire in-app: **stop, do
   not ship a watchdog or timeout**, revert the policy commit, and report the
   finding to the owner with the log evidence.

7. **Docs in the same PR.**
   - ARC-023: replace "large or background reorder-only changes shall use
     AppKit's reloadData-class diffable fallback (`animatingDifferences:
     false`); at current ~23k library scale that apply and zero-duration
     true-diff measure in the same ~110–250 ms ballpark…" with the Part C
     behavior specification and the post-change measured numbers.
   - APP-006: "the reloadData-class fallback for large/reorder-only applies
     stays unanimated" → same-descriptor reorders animate; descriptor-change
     and large membership applies stay unanimated.
   - ADR 0006: rewrite the apply-policy paragraph and the Context sentence
     "The remaining scroll hitch under Best Date enrichment is how often those
     applies run" — after Part C the frequency is unchanged and the hitch is
     gone; cite the research doc table and the shipped verification numbers.
   - ADR 0011: the consequence line "Background enrichment may visibly reorder
     assets or change filter membership; this is correct behavior, not a
     special-case animation path" — keep the first half, replace the second:
     the reorder is ordinary truth adopted every background tick and now
     renders as animated moves per ADR 0006.

**Magnitude bound (why no mover-count machinery):** same-descriptor reorder
applies can only originate from enrichment/scan fact changes accumulated within
one 1-second projection tick; observed batches move 1–3 assets, bounded by the
enrichment batch caps — orders of magnitude below the measured comfort zone
(33 ms at K = 200, ~88 ms at K = 1,000). Do **not** add LIS/mover-count gating
now; if a future change introduces a same-descriptor mass-reorder source,
re-measure against the research doc table first.

## Increment / PR breakdown

| PR | Contents | Oracle |
| --- | --- | --- |
| 1 | Parts A (residual) + B (behavior-preserving hot-path fixes) | All existing tests green **unmodified**; new pin/cache tests; before/after capture (`pinMs`, `applyCallMs`, hang table) |
| 2 | Part C (+ ADR 0006/0011, ARC-023, APP-006) | Policy truth-table tests; paint-invariant/selection tests green unmodified; in-app completion gate passed; capture shows animated applies at the 1 s cadence with a clean hang table |

Standard repo process applies to each PR: dedicated worktree + conventional
branch prefix, `script/verify.sh` with Xcode 27, review-comment scan of the
last five PRs (#78 included), code-smells note, and no docs left stale in the
same PR.

## Verification protocol (repeat per PR, attach artifacts)

1. `script/build_and_run.sh` against the production OneDrive library while
   enrichment is still incomplete (check
   `SELECT COUNT(*), SUM(enriched_source_mtime IS NOT NULL) FROM media_asset;`
   in `~/Library/Application Support/net.melisma.Otos/Catalog/catalog.sqlite`
   — if enrichment finished, re-seed a fixture library or reset a scratch
   catalog; the storm only exists while dates are being written).
2. `script/logs.sh stream` in the background; scroll continuously for ~60 s.
3. `xcrun xctrace record --template 'SwiftUI' --attach Otos --time-limit 60s`.
4. Compare against the 2026-07-09 pre-#78 baseline **and** a fresh post-#78
   baseline captured before PR 1 (attach both):
   - `grep -c mainThreadStall` on the run log (pre-#78 baseline: 32/55 s);
   - hangs table via `script/profile-export.sh <trace> --xpath
     '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]'`
     (pre-#78 baseline: 11 hangs, worst 510 ms);
   - `op=ui.mediaGrid.structuralApply` count and the
     `applyCallMs`/`completionMs`/`applyMs` split (pre-#78 baseline: ~18/min at
     applyMs 173–226 ms) plus `phase=finish` liveness (completion gate, PR 2);
   - `op=ui.mediaGrid.reconfigure` `pinMs`/`ensureMs`/`renderMs` (PR 1);
   - `op=ui.mediaGrid.scrollBounds` window counters for scroll-path sanity.

**Done means:** during 60 s of continuous scrolling with enrichment active —
zero Hangs-table entries, structural applies continuing at the full enrichment
cadence (~1/s when order changes) with `applyCallMs` < 50 ms, `mainThreadStall`
faults rare and < 250 ms with no `applyStructure` attribution storm, and no
regression in thumbnail arrival latency (`MediaGridVisibleDetailQuery` spans).
Visual confirmation that moves animate is desirable but not a DoD condition
(agent-owned verification; completion-liveness and policy tests are the
mechanical proxies).

## Risks and mitigations

- **Animated-apply completion might not fire in-app for move-only batches**
  (harness caveat). Hard gate in Part C step 6; abort-and-report path defined.
  No watchdog. #78's `pendingGrid` stall field makes a jammed gate visible.
- **Quadratic diff cliff for mass reorders.** Structurally bounded (see
  magnitude bound); descriptor-changed reorders — the only whole-list case —
  keep the fallback. Documented table in the research doc for any future
  re-check.
- **Once-per-second animated movement could read as visual churn.** The owner
  explicitly chose per-second adoption with animations. Tuning knob is
  `MediaGridAnimation.applyDuration` (0.35 s); an apply arriving mid-animation
  parks in the gate and drains on completion (existing newest-wins semantics).
- **Additive `pin(_:)` grows the pinned set within one pass** (scroll during
  apply). Bounded by the pass boundary that replaces the set on every
  merge/reconfigure/apply completion; worst case is a briefly larger pinned
  set — never a blank.
- **Enrichment completes on the dev library before verification.** Use the DB
  check in protocol step 1 and a scratch catalog reset (the catalog is a
  rebuildable projection; never touch originals).

## Explicit non-goals

- No publication-cadence changes anywhere: projection stays at ~1 s background
  coalescing + immediate user intents; enrichment `applyFlushInterval` stays
  1 s. (A slower reorder-adoption cadence was proposed and rejected by the
  owner on 2026-07-09.)
- No changes to #78's scroll coalescing or its diagnostics shape.
- No custom collection-view data source, no LIS/mover-count machinery, no new
  caches beyond the two-entry placeholder icon cache.
- The `visibleLifecycle` log volume and the all-at-once enrichment lease
  observation from the diagnosis are out of scope (no observed correctness or
  jank impact).
