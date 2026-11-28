# Grid Reorder Cadence, AppKit Diffable Apply, And Placeholder Symbol Cost

Status: non-authoritative research note.

Date: 2026-07-09

This document records the evidence and API research behind plan 0008 (grid jank
remediation). It is design input, not proof that current behavior exists and not
a commitment to implement a specific option.

## Questions

1. Why did the media grid start hanging during scrolling, and what exactly is on
   the main thread?
2. What is AppKit's `NSCollectionViewDiffableDataSource` actually capable of —
   specifically, can a background reorder be applied *animated* at real-library
   scale (23k items)?
3. Is creating `NSImage(systemSymbolName:)` per call expensive enough to matter,
   and what is the accepted practice?
4. What do platform best practices say about frequent snapshot applies driven by
   background metadata ingest?

## Evidence: instrumented run (2026-07-09)

Debug build, 23,043-asset OneDrive library, ~55 s of user scrolling while
background enrichment ran. Artifacts:

- Instruments trace: `build/Profiles/SwiftUI-jank-20260709-114428.trace`
  (SwiftUI template: Time Profiler, Hangs, hitches; deleted 2026-11-10 to free disk,
  so the figures below are its only record).
- Unified log capture: `logs/run-20260709T184420Z-p77645-prod.log`.

Findings, cross-confirmed between the Hangs table, the debug
`MainRunLoopStallMonitor` fault lines, and the `op=` log records:

- 11 main-thread hangs of 266–510 ms in 55 s; every stall-monitor fault is
  tagged `lastOp=MediaGridViewController.applyStructure`.
- 31 projection publications in ~60 s (one per enrichment flush);
  18 had `mediaIdentityChanged=true` and each produced one structural apply with
  `inserted=0 removed=0 reorderOnly=true reloadDataFallback=true` and
  `applyMs=173–226` on 23,011 items. The identity changes are genuine: the sort
  is `bestDate:descending`, enrichment writes EXIF timestamps
  (`ts_original_unix` → generated `best_capture_unix`), so each 1–3-asset flush
  reorders the whole list. The ORDER BY has a deterministic `relative_path`
  tiebreaker, so this is not query nondeterminism.
- Catalog state at capture time: 23,043 assets, 4,836 enriched. The enrichment
  tail is hours long (cloud materialization bound), so every session hits this
  storm until enrichment completes.
- Time profile, main thread, 17.7 s running over 55 s (deepest app frame):
  - 2.79 s `MediaAssetTileView.updatePlaceholderPresentation()`, of which
    1.60 s is `NSImage(systemSymbolName:accessibilityDescription:)` — a fresh
    SF-Symbol `NSImage` per layout pass per placeholder tile.
  - 2.19 s `MediaGridViewController.visibleAssetIDs()` plus ~0.55 s
    `pinVisibleIDs()`/hashing satellites — `ensureContentAndMaybeDecode` re-pins
    the *entire* visible set once per tile bind, making every reconfigure/reload
    pass O(visible²).
  - ~6.0 s in stacks whose only app frame is `OtosApp.$main` — AppKit layout,
    item instantiation, and render work, dominated by the per-second
    reloadData-class applies.
- Both hot app paths (`ensureContentAndMaybeDecode`/`pinVisible`) were
  introduced by plan 0005 (PR #65) and reshaped by plan 0001 Part 2 (PR #74),
  which is why the jank surfaced in this PR window. The placeholder symbol
  allocation predates it (PR #52) and was amplified by the apply storm plus a
  79 %-placeholder library.

## Local API capability findings (macOS 27 SDK, Xcode 27 beta)

Verified directly in
`MacOSX27.0.sdk/System/Library/Frameworks/AppKit.framework`:

- `Headers/NSDiffableDataSource.h` — AppKit's diffable API is still the
  macOS 10.15 surface. The only apply is
  `applySnapshot:animatingDifferences:`, documented in the header as:
  "To perform an animated diff of the changes: animatingDifferences == YES.
  For non-animated update (i.e. reloadData) without the diff overhead:
  animatingDifferences == NO."
  There is **no** `applySnapshotUsingReloadData`, **no**
  `reconfigureItems(_:)` on the snapshot (only `reloadItemsWithIdentifiers:`),
  and no section snapshots. The Swift overlay
  (`Modules/AppKit.swiftmodule/arm64e-apple-macos.swiftinterface`) adds only a
  `completion:` parameter — no async or reload-style variants.
- `Headers/NSCollectionView.h` — the classic data-source path has
  `performBatchUpdates(_:completionHandler:)` and animatable
  `moveItem(at:to:)`/`insertItems`/`deleteItems` via the `animator()` proxy.
  These are **not** combinable with an installed diffable data source (the
  diffable data source owns index-path truth; imperative moves desync its
  snapshot). Using them would mean replacing the diffable data source with a
  hand-rolled `NSCollectionViewDataSource`.
- UIKit divergence (context for readers of UIKit-era advice): since iOS 15,
  UIKit's `apply(_:animatingDifferences:)` *always diffs* (optionally without
  animation) and offloads diffing off-main, and UIKit gained
  `applySnapshotUsingReloadData` + `reconfigureItems`. **None of that applies to
  AppKit.** On macOS, `animatingDifferences: false` is reloadData, and
  `animatingDifferences: true` is a main-thread diff.

## Prior in-repo measurement: withdrawn

ADR 0006 previously justified the reloadData-class fallback
(`reorderOnly || items ≥ 1000` in `MediaGridStructuralApplyPolicy`) with a
spec-0039-era true-diff timing. That measurement was declared **stale**
on 2026-07-09 and it has been removed from the ADR; no prior in-repo number
constrains the animation question. The current fallback's measured cost in this
run's signposts is ~90 ms for the apply call plus ~100 ms of completion work at
23k items, up to once per second.

Fresh measurements of `apply(_:animatingDifferences: true)` at real-library
scale are recorded in the "Spike results" section below and are the only
apply-cost numbers that should be cited going forward.

## Spike results (2026-07-09): animated diffable apply cost at n = 23,043

Standalone harness (`script/poc-diffable-apply-bench.swift`, compiled `-O` via
`xcrun swiftc`; env knobs `BENCH_N`, `BENCH_KLIST` (−1 = full reversal),
`BENCH_REPS`, `BENCH_SPIN`; Apple-silicon MacBook Pro, macOS 27 beta): NSCollectionView in a 1200×800
window, the production compositional layout (6 columns, square cells, same
insets), an `NSCollectionViewDiffableDataSource<Int, BenchID>` where `BenchID`
is a two-string Hashable struct with realistic path contents mimicking
`MediaAssetID`, 24 items visible. K items were moved to random positions
between same-membership snapshots (K = −1 denotes full order reversal); worst
of the repetitions shown, call-to-return on the main thread:

| Case | `animatingDifferences: true` | `animatingDifferences: false` |
| --- | --- | --- |
| initial load 0 → 23k | — | 3–6 ms |
| K = 0 (identical order) | 10.7 ms | — |
| K = 1 | 27.0 ms | — |
| K = 3 | 28.1 ms | 1.9 ms |
| K = 10 | 28.3 ms | — |
| K = 50 | 28.9 ms | — |
| K = 200 | 33.1 ms | 1.6 ms |
| K = 1,000 | 88.3 ms | — |
| K = 5,000 | 1,041 ms | — |
| full reversal (K ≈ 23k) | 30,245 ms | — |

Readings:

- **The enrichment trickle case (K = 1–3, once per second) costs ~23–28 ms
  animated** — well under the 100 ms hang threshold, affordable at a 1 s
  cadence. There is an ~10 ms O(n) diff floor (K = 0) plus a cost that grows
  roughly quadratically in the moved-item count: ~90 ms at K = 1,000, ~1 s at
  K = 5,000, ~30 s for a full reversal. Whole-list reorders (e.g. a sort-
  direction flip) must never take the animated path; small-delta reorders are
  cheap.
- The ~30 s full-reversal figure plausibly explains the withdrawn spec-0039-era
  measurement: a pathological whole-list case was generalized to all reorders.
- `animatingDifferences: false` is 1–2 ms *in the harness* because the harness
  item provider is trivial. In production the same call measures ~90 ms
  (signposts) plus ~100 ms completion work, because reloadData tears down and
  recreates every visible item, and each recreation runs the app's bind path
  (which plan 0008 Parts A/B make cheap, but which can never be free ×90 ×1/s).
  The apply mechanics were never the bottleneck — the visible-item teardown is.
- **Caveat — completion handler:** in this harness the `completion:` closure
  never fired for `animatingDifferences: true` (any K, key window, 3 s of run
  loop), while it fired immediately for `false`. In the production app,
  animated small insert/remove applies (spec 0047) demonstrably complete —the
  mutation gate would jam otherwise — so this is presumed a harness-environment
  artifact (no display-synced animation commit in a bare CLI app). Any adoption
  of animated *move-only* applies must verify in-app that
  `op=ui.mediaGrid.structuralApply phase=finish` keeps firing (it is logged
  from the completion) before shipping.

## SF Symbol image creation

- The AppKit header (`NSImage.h`) documents
  `imageWithSystemSymbolName:accessibilityDescription:` as "Creates a system
  symbol image…" — a new instance per call; no caching promise is documented.
- Our trace attributes 1.6 s / 55 s of main-thread time to these initializers
  when called from `layout()` per placeholder tile.
- Community practice for symbol-heavy UIs is to resolve the symbol once per
  (name, configuration) and reuse the instance; e.g. symbol-rendering libraries
  cache resolved images per configuration.
- Otos needs exactly two placeholder icons (photo, film). A static per-kind
  cache removes the allocation entirely; assignment can additionally be skipped
  when the rendered kind did not change.

## Best-practice synthesis for frequent background-driven snapshots

From Apple's diffable-data-source guidance, WWDC 2021 "Make blazing fast lists
and collection views", the existing repo research
(`docs/research/media-grid-best-practices.md`), and the measurements above:

- Structural identity changes and detail changes need different paths (already
  the case in Otos); *detail* arrival must never force structural applies
  (already the case — thumbnail arrival flows through `detailRefreshGeneration`
  and visible reconfigure).
- Apple's guidance — prefer applying snapshots (diffing) over reloading,
  because reload throws away existing cells — holds on AppKit too, per the
  spike: a small-delta animated diff costs ~25 ms at 23k while the
  reloadData-class path costs ~200 ms in production, entirely because it tears
  down and recreates every visible item and re-runs the app's bind path for
  each. The per-second reorder *cadence* is affordable; the reload *mechanics*
  are what janks.
- The animated diff has a quadratic-in-moves cliff (spike table). Policy must
  distinguish the small-delta reorder (enrichment trickle, K = 1–3/s — animate)
  from whole-list reorders (sort flips — keep the unanimated reloadData-class
  path; they reset scroll anyway and have no animation value).
- Visible-set bookkeeping must be O(visible) per pass, not O(visible²): compute
  the visible set once per pass boundary and pass it down; per-item binds may do
  O(1) additive work only.

## Status update (2026-07-09, later the same day)

PR #78 landed on `main` independently: scroll-bounds coalescing (~16 ms
trailing edge, unchanged-ID detail-query skip), once-per-pass pinning for the
reconfigure path, per-phase apply diagnostics
(`diffPolicyMs`/`snapshotBuildMs`/`applyCallMs`/`completionMs`), and its own
in-app measurement — at ~23k the reloadData-class apply and a zero-duration
true-diff both land in a ~110–250 ms `applyMs` ballpark — corroborating this
doc's finding that true-diff is not pathological (in-app `applyMs` folds in
completion work and the dequeue-pass pin walk that plan 0008 Part A removes;
the harness isolates the bare apply call). The dequeue path still pins the
whole visible set per item (`makeCollectionItem`), and the placeholder-icon
allocation and unanimated reorder policy are unchanged — those remain plan
0008's Parts A (residual), B, and C.

## Conclusions

1. The jank is the product of three multiplying factors: per-second
   same-membership reorder publications during enrichment (~18/min), a
   ~200 ms reloadData-class apply at 23k items each, and O(visible²) + per-tile
   symbol-allocation overhead added/amplified in the recent tile-store PRs.
2. The reorder cadence is **not** the problem and stays at once per second
   (product decision: fix the jank, do not make it rarer). The fix is
   the apply policy plus the bind-path costs: (a) visible-set bookkeeping
   O(visible) per pass, (b) cached placeholder icons, (c) route same-descriptor
   small-delta reorders through `apply(animatingDifferences: true)` — measured
   ~25 ms at 23k for the K = 1–3 trickle — which both removes the visible-item
   teardown that causes the jank and animates the moves, matching the stated
   preference. Whole-list reorders and descriptor changes keep the unanimated
   reloadData-class path (quadratic cliff, spike table).
3. Adoption must verify in-app that animated move-only applies fire their
   completion (see spike caveat); if AppKit's completion proves unreliable
   there, the finding goes back for a product decision before any workaround is designed.

## Post-fix run (2026-07-09, after PRs #78–#80 / plan 0008)

Instrumented scroll run: log `logs/run-20260709T235830Z-p6981-prod.log`, trace
`build/Profiles/SwiftUI-postfix-20260709-165836.trace` (deleted 2026-11-10; ~2 min attach,
enrichment active at ~4.9k/23,045 enriched).

- Plan 0008 behaves as designed: 26/26 structural applies animated
  (`animatingDifferences=true`, `reloadDataFallback=false`), completions fire
  (no jammed gate), reconfigure ≤ 27 ms with `pinMs=0`,
  `updatePlaceholderPresentation` down from 2.8 s/55 s to 0.42 s/135 s.
- Jank persists: 95 `mainThreadStall` faults (~3 min log), 31 hangs
  253–714 ms (120 s trace), 9 back-to-back hangs in one 8 s hard-scroll
  stretch.
- Residual 1 — per-apply main-actor bookkeeping, ~130–170 ms/apply at 1/s:
  `diffPolicyMs` 27–65 (Set(23k) in `summarize`), `snapshotBuildMs` ~30,
  `applyCallMs` ~43 (matches this doc's benchmark), `completionMs` ~27
  (`prune`'s Set(23k)). Hashing/equality of
  `MediaAssetID`/`LibraryRootPath`/`MediaRelativePath` totals ~1.7 s of
  main-thread time whole-run.
- Residual 2 — Core Animation commit pressure: 3.0 s of the 5.0 s
  hang-window main-thread time sits under `CA::Transaction::commit`, of which
  ~1.5 s is `mach_msg` (commit blocked on the render server) and ~0.24 s is
  `CVPixelBuffer` → IOSurface copies of thumbnail `layer.contents`; driver is
  scrolling concurrent with the 0.35 s move animation firing every second.
- Visible-thumbnail latency is a separate fact: viewport prioritization works
  (`downloadDispatched … viewport=true`), but one visible RAW took ~50 s of
  OneDrive materialization through the 4-worker download pool before its ~1.5 s
  enrich-and-paint. Grid is not the bottleneck; recorded as a roadmap idea.

Remediation landed as plan 0009 (PRs #81–#83): prune skip + retained
previous-order Set; scroll-time animation suppression; measured
`MediaAssetID` fingerprint hashing; CA-commit/IOSurface spike deferred to
Instruments evidence; tile badge rework (painted-only video duration / film
fallback / RAW). The plan file was deleted when Part E landed.

## Plan 0009 PR1 capture (2026-07-09, Parts A+B)

Log `logs/run-20260710T002818Z-p10790-prod.log` (smoke scroll against OneDrive
library). Representative same-descriptor reorder at n = 23,016:

- `diffPolicyMs=18` (was 27–65) — retained `displayedOrderedIDSet`
- `completionMs=13` (was ~27) — prune skipped on reorder-only
- `animationSuppressed=true` during scroll
- `applyMs=108` (was 128–166); `snapshotBuildMs=31` / `applyCallMs=47` unchanged
  (Part C owns those)

## Plan 0009 PR2 capture (2026-07-09, Part C fingerprint)

Log `logs/run-20260710T003453Z-p14102-prod.log`. Three reorder-only applies at
n = 23,016 while scrolling with enrichment active:

| metric | post-PR1 | post-fingerprint | delta |
| --- | --- | --- | --- |
| `diffPolicyMs` | 18 | 8–9 | ~half again |
| `snapshotBuildMs` | 31 | 16–17 | ~half |
| `applyCallMs` | 47 | 29–36 | ~30% |
| `snapshotBuildMs+applyCallMs` | ~78 | med 46 / max 53 | clear win; ~40 ms target nearly met |
| `completionMs` | 13 | 7–8 | — |
| `applyMs` | 108 | 63–68 | ~40% |

Measurement gate: land Part C — combined snapshot+apply is a clear reduction
from the hash-dominated baseline even though median 46 ms sits slightly above
the ~40 ms aspirational line. Codable/persistence remain raw path strings only;
fingerprint is derived Hashable state.

## Plan 0009 Part D spike (2026-07-09, after A–C)

Same PR2 smoke log: 14 `mainThreadStall` mentions remain in a ~70 s settle+scroll
window (down from 95 in the post-0008 ~3 min baseline, not hang-zero). Reorder
`applyMs` is now 63–68 ms — under the 100 ms hang threshold for the apply itself —
so residual stalls during continuous scroll are consistent with the earlier
CA-commit / IOSurface diagnosis (Part D), not the O(n) bookkeeping Part C
targeted. No decode-format or animation-duration code ships in this PR: Part D
requires a before/after Instruments hang-window stack showing
`CA::Transaction::commit` / `mach_msg` shrinking before any change. Next
evidence step: `script/profile.sh "SwiftUI" 60s` (or Hangs) during continuous
scroll with enrichment active, then decide decode-format vs idle animation
duration.

## Plan 0009 final verification run (2026-07-09, all parts landed)

User scroll session, ~2 min attach with enrichment active (~5.1k/23,048):
log `logs/run-20260710T021345Z-p19675-prod.log`, trace
`build/Profiles/SwiftUI-plan0009-20260709-191352.trace` (deleted 2026-11-10; the
aggregates below are its only record).

- **Instruments Hangs table: 0 rows** (plan-0008 verification run: 31; original
  diagnosis run: 11). The apply-path jank is fixed at the platform-authoritative
  detector.
- 17 structural applies, all animated true-diffs; 6 ran with
  `animationSuppressed=true` during live scroll. Per-apply bookkeeping as
  designed: `diffPolicyMs` 8–10, `snapshotBuildMs` 16–19, `completionMs` 10–11.
  Unsuppressed (idle) applies report `applyCallMs` ≈ 385–401 — that is the
  completion waiting out the 0.35 s move animation (wall time), not main-thread
  blockage; the hangs table confirms.
- Frame hitches: 1,718 total (p50 12.5 ms, p90 25 ms — one to three 120 Hz
  frame periods under heavy scroll), of which 43 ≥ 100 ms, worst 441 ms,
  clustered in the hardest-scroll windows. Those windows contain **no
  structural applies** — activity is scroll flushes, visible reconfigures, and
  cloud-download completions painting thumbnails — consistent with the Part D
  CA-commit/IOSurface-upload diagnosis, now demoted from "hangs" to "bursty
  late frames while the main thread stays responsive." Part D remains
  open/evidence-first; whether it proceeds is a product feel/priority call.
- Debug `MainRunLoopStallMonitor` logged 65 faults (worst 637 ms) against the
  0-row hangs table; its timer-lateness signal over-reports under continuous
  display load and its `lastOp` attribution can reference operations tens of
  seconds old. Follow-up: tighten the monitor (tolerance, attribution decay)
  so it agrees with Instruments about what a stall is.

## Mid-scroll residual analysis (2026-07-09, plan 0009 final trace)

Aggregating main-thread stacks inside the 43 ≥100 ms hitch windows of
`SwiftUI-plan0009-20260709-191352.trace` (brief mid-scroll pauses are still felt
despite the 0-row hangs table):

- Dominant: render-pipeline commit — `CA::Transaction::commit` blocked in
  `mach_msg` (~650 ms across windows), `CVPixelBuffer` → IOSurface copies of
  thumbnail contents (~102 ms), `NSViewBackingLayer display` (~90 ms),
  `_NSViewSubViewMutationSafeApply` (~78 ms). The main thread stays responsive
  (no Hangs rows) but frames arrive late while commits wait on the render
  server.
- Notable app-side slices inside the same windows: **signpost/OSLog emission
  ~107 ms** (debug-build observability cost on the scroll path),
  apply-adjacent work (`applySnapshot` 39, gate completion 37,
  `GridSelection.pruned` 40, `mediaSnapshot` 26), `videoBadgeText` formatting
  per bind (~31), `visibleAssetIDs` (27), fingerprint computation (28).
- Scroll coalescing itself is healthy: ~44–68 bounds ticks/s collapse to 1–4
  flushes with detail queries mostly skipped-unchanged.

Evidence-ranked levers for the remaining mid-scroll tail:

1. Defer structural applies while a live scroll is in progress (park
   `pendingGrid` in the gate; drain on ~250 ms quiet — same signal Part B
   uses). Removes apply-driven layout/commit churn from scroll entirely;
   applies resume immediately on pause. Product sign-off required (adjacent to,
   but distinct from, the rejected cadence holdback: publication cadence is
   untouched; adoption defers only while the finger is down).
2. Part D decode-format: decode thumbnails into IOSurface-friendly
   premultiplied BGRA so `layer.contents` assignment stops copying at commit.
3. Debug observability cost: move per-flush scroll-path signposts/logs behind
   a verbosity gate; capture one RELEASE-build trace to measure true UX
   numbers (all captures so far are Debug builds).
4. Cache the formatted duration string per detail (avoid `Duration.formatted`
   on every bind), and only mutate badge subviews on content change (subview
   mutation appears in commit stacks).
5. Micro: skip `GridSelection.pruned` when selection is empty.

## Sources

- Local SDK headers (primary): `NSDiffableDataSource.h`, `NSCollectionView.h`,
  `NSImage.h`, and `AppKit.swiftmodule/arm64e-apple-macos.swiftinterface` in
  `MacOSX27.0.sdk` (paths above).
- In-repo primary evidence: trace and log artifacts listed above; ADR 0011
  (publication cadence ownership); `docs/research/media-grid-best-practices.md`.
- [Apple: Updating collection views using diffable data sources](https://developer.apple.com/documentation/uikit/updating-collection-views-using-diffable-data-sources)
- [Apple: NSImage.SymbolConfiguration](https://developer.apple.com/documentation/appkit/nsimage/symbolconfiguration)
- [Apple: init(systemSymbolName:accessibilityDescription:)](https://developer.apple.com/documentation/appkit/nsimage/3622472-imagewithsystemsymbolname)
- [Apple WWDC 2021: Make blazing fast lists and collection views](https://developer.apple.com/videos/play/wwdc2021/10252/)
- [Jesse Squires: Diffable data source behavior changes and reconfiguring cells in iOS 15](https://www.jessesquires.com/blog/2021/07/08/diffable-data-source-behavior-changes-and-reconfiguring-cells-in-ios-15/)
  (documents the iOS 15 divergence; AppKit did not receive these changes)
- [Apple Developer Forums: Applying new snapshot to diffable data source in iOS 15](https://developer.apple.com/forums/thread/683775)
- [eon.codes: Diffable collection view for macOS](https://eon.codes/blog/2021/08/25/diffable-collection-view-for-macOS/)
  (community AppKit diffable notes; no large-scale performance data)
