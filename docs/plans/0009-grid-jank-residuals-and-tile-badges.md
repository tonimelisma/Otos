# Plan 0009: Grid Jank Residuals + Tile Badge Rework (Video Duration, RAW Tag)

Status: active. Delete this file when all parts have landed on `main`.

Owner evidence (post-plan-0008 instrumented run, 2026-07-09): log
`logs/run-20260709T235830Z-p6981-prod.log`, trace
`build/Profiles/SwiftUI-postfix-20260709-165836.trace`. Findings recorded in
`docs/research/grid-reorder-cadence-and-appkit-diffable-apply.md` ("Post-fix
run" section). Diffable-apply benchmark: `script/poc-diffable-apply-bench.swift`.

## Where plan 0008 left the jank (measured)

Plan 0008 landed (#78–#80) and works as designed: all 26 structural applies in
the verification run were animated true-diffs (no reloadData teardown for the
enrichment trickle), reconfigure passes cost ≤ 27 ms, placeholder-icon churn is
gone. But the run still shows 95 main-thread stalls and 31 hangs (253–714 ms)
in ~2 minutes of scrolling. Two residual costs, precisely attributed:

1. **~130–170 ms of main-actor work per apply, around the diff.** Per-phase
   fields from a representative apply at n = 23,016:
   `diffPolicyMs=27–65` (`summarize` builds a `Set` of 23k two-string IDs),
   `snapshotBuildMs=30` (rebuild the 23k-item diffable snapshot),
   `applyCallMs=43` (the diff itself — matches the benchmark),
   `completionMs=27` (`prune` builds another `Set(23k)`), total
   `applyMs=128–166`. At the once-per-second cadence this alone exceeds the
   100 ms hang threshold. All 95 stalls carry `lastOp=applyStructure`.
2. **Core Animation commit pressure: 3.0 s of the 5.0 s of hang-window
   main-thread time.** Inside `CA::Transaction::commit`: ~1.5 s blocked in
   `mach_msg` (commit waiting on the render server) and ~0.24 s of
   `CVPixelBuffer` → IOSurface copies (thumbnail `layer.contents` uploads).
   Driver: fast scrolling concurrent with a 0.35 s move animation firing every
   second.

Supporting profile fact: hashing/equality of `MediaAssetID` /
`LibraryRootPath` / `MediaRelativePath` totals ~1.7 s of main-thread time in
the 135 s run (protocol-witness `hash(into:)`/`==` frames) — these types are
hashed and compared wholesale (23k at a time) in `summarize`, snapshot build,
the diff, the gate's identity equality, and `prune`.

## Owner decisions captured (2026-07-09)

- Once-per-second reorder cadence stays (carried over from plan 0008).
- **Animations while the user is actively scrolling are unnecessary** —
  suppress the move animation during live scrolling; the apply itself still
  happens (still a true diff — never reintroduce the reloadData teardown for
  the trickle).
- Video badge rework and a RAW badge (Part E below), rules verbatim:
  - Before enrichment, the lower-right shaded badge currently shows a film
    icon — redundant with the centered film placeholder icon. Remove it: **no
    lower-right badge on a placeholder tile.**
  - Once the thumbnail is painted: show the clip length in the shaded area;
    show the film icon there **only** when the clip length is missing (owner
    expects duration to almost always exist when a thumbnail exists — both are
    written by the same enrichment batch; the icon covers failed duration
    extraction).
  - **Center-justify the duration text** within the shaded area.
  - Add a matching lower-right shaded tag with the word **RAW** for raw
    images.

## Invariants (unchanged from plan 0008)

- APP-015 no-blank invariant; paint-invariant and TileContentStore tests stay
  green **unmodified**.
- One implementation path: projection → ViewModel → bridge → gate → controller.
- Selection preservation across same-descriptor applies (APP-010/011).
- Every part ships with before/after log or trace evidence
  (`script/verify.sh` plus the capture protocol below).

---

## Part A — Cut the per-apply O(n) bookkeeping (quick wins)

**Files:** [Otos/Views/MediaGridStructuralApply.swift](../../Otos/Views/MediaGridStructuralApply.swift),
[Otos/Views/MediaGridSupport.swift](../../Otos/Views/MediaGridSupport.swift),
[Otos/Views/MediaGridMutationGate.swift](../../Otos/Views/MediaGridMutationGate.swift)

1. **Skip `prune` on reorder-only applies.** In `completeStructuralApply`
   (MediaGridStructuralApply.swift:153), `tileContents.prune(to:
   Set(context.grid.orderedAssetIDs))` builds a 23k-ID `Set` per apply. A
   reorder-only apply has identical membership by definition
   (`context.reorderOnly` is already in the completion context), so the prune
   is a no-op that costs ~27 ms. Guard it:
   `if !context.reorderOnly { tileContents.prune(...) }`. Budget enforcement
   is unaffected (`applyDecoded` already enforces on every insert).
2. **Stop re-hashing the previous order every apply.** `summarize`
   (MediaGridSupport.swift) rebuilds `Set(previousOrderedIDs)` on each call —
   but "previous" is always the gate's `displayedOrderedIDs`, which was the
   previous apply's `nextOrderedIDs`. Have the gate retain
   `displayedOrderedIDSet: Set<MediaAssetID>` alongside `displayedOrderedIDs`
   (MediaGridMutationGate.swift:84, updated at :138), and pass it into
   `summarize` instead of the array-to-Set rebuild. Roughly halves
   `diffPolicyMs`. Keep the `Set` and array updated in exactly one place
   (`completeStructuralApply(applied:)`); assert consistency in gate tests.
3. Do **not** touch `snapshotBuildMs`/`applyCallMs` here — Part C addresses
   the hashing that dominates them; snapshot mutation/reuse machinery is out
   of scope (measure Part C first).

**Oracle:** behavior-preserving. Existing tests green unmodified; new gate test
for the retained-Set consistency; capture shows `completionMs` ≈ single-digit
and `diffPolicyMs` roughly halved on reorder applies.

## Part B — Suppress move animation during live scrolling

**Files:** [Otos/Views/MediaGridBridge.swift](../../Otos/Views/MediaGridBridge.swift),
[Otos/Views/MediaGridStructuralApply.swift](../../Otos/Views/MediaGridStructuralApply.swift),
[Otos/Views/MediaGridAnimation.swift](../../Otos/Views/MediaGridAnimation.swift)

Owner decision: animating moves the user cannot watch (mid-scroll) buys
nothing and feeds the CA-commit pressure (0.35 s animation × 1/s applies ×
scroll commits). Suppress the **animation**, never the diff:

1. The controller already receives every scroll tick in
   `scrollBoundsChanged()`. Record `lastScrollTickAt: Date` there (one Date
   assignment; no new observers — reuse the existing bounds notification).
2. Add a pure decision helper (unit-testable, e.g. in `MediaGridAnimation`):

   ```swift
   /// During live scrolling a move animation is invisible churn; apply
   /// instantly instead. Threshold: one coalesced scroll window is 16 ms;
   /// 250 ms of quiet means the user has plausibly stopped.
   nonisolated static func suppressesApplyAnimation(
       lastScrollTickAge: TimeInterval
   ) -> Bool {
       lastScrollTickAge < 0.25
   }
   ```

3. In `applySnapshot(_:summary:completion:)`, when
   `summary.animatingDifferences` is true but suppression is active, still
   call `dataSource.apply(snapshot, animatingDifferences: true, …)` but set
   `NSAnimationContext.current.duration = 0` (keep the group so completion
   semantics stay identical). **Never** downgrade to
   `animatingDifferences: false` — that is the reloadData teardown plan 0008
   removed.
4. Log the suppression on the structural-apply finish line
   (`animationSuppressed=true/false`) so captures can correlate.

**Oracle:** policy truth-table tests unchanged (`animatingDifferences` is
untouched); new unit test for the threshold helper; capture during continuous
scroll shows `animationSuppressed=true` applies and reduced hang density in
the scroll stretches.

## Part C — Cheapen identity hashing with a precomputed fingerprint (measured)

**Files:** [Otos/Models/CatalogModels.swift](../../Otos/Models/CatalogModels.swift)
(`MediaAssetID` and its `LibraryRootPath`/`MediaRelativePath` components)

**Why:** ~1.7 s of main-thread hashing/equality in the 135 s run, spread
across `summarize`, snapshot build (23k ObjC-bridged hash inserts), the diff,
gate equality, and `prune`. `MediaAssetID` hashes two full path strings every
time.

**Design:** store a fingerprint computed once at init —
`let fingerprint: UInt64` = a **stable, process-independent** hash (e.g.
FNV-1a over both strings' UTF-8; do not use `Hasher`, whose seed is
per-process) — and implement:

- `hash(into:)` combines only `fingerprint`;
- `==` fast-paths on `fingerprint` inequality, then falls back to full string
  comparison on equality (collisions must not produce false equality).

Constraints for the implementer:

- Equal string pairs must always produce equal fingerprints (determinism);
  document that the fingerprint is derived state, never persisted, never
  logged as identity.
- `MediaAssetID` is the diffable identifier — ObjC bridging uses `hashValue`,
  which now flows through the fingerprint; that is the point.
- Blast radius: every `MediaAssetID`/component initializer call site;
  Codable/persistence representations must remain the raw strings only.

**Measurement gate (hard):** land only if the capture shows a clear win —
target `snapshotBuildMs` + `applyCallMs` combined ≤ ~40 ms and the
protocol-witness hash/== frames dropping to noise in the hang windows. If the
win is marginal, drop this part and record the numbers in the research doc.

**Oracle:** all existing tests green unmodified (Hashable semantics are
contract-identical); add an equality/hashing property test (equal IDs ⇒ equal
fingerprints; differing fingerprint ⇒ `!=`).

## Part D — Render-pressure spike: CA commit and IOSurface copies (investigate, then decide)

**Question:** after Parts A–C, do hangs persist with `CA::Transaction::commit`
blocked in `mach_msg` during scroll?

1. Re-run the capture protocol; aggregate hang-window stacks (aggregation
   scripts from the 2026-07-09 sessions; app frames live under the
   `Otos.debug.dylib` binary in xctrace exports).
2. If commit-blocking persists, investigate in order:
   - **Decode format:** thumbnails decode via `ThumbnailStore.load` to
     `CGImage`s that CA copies into IOSurfaces at commit
     (`CVPixelBufferBacking::…CopyIOSurfaceCreationProperties` in the
     profile). Measure decoding into premultiplied-BGRA bitmap contexts (or
     IOSurface-backed images) so commits stop copying; 256 px thumbnails are
     ~256 KB each — 90 visible × scroll rate is the churn.
   - **Animation window:** with Part B, animations only run when idle; if
     idle-time applies still hang, measure `MediaGridAnimation.applyDuration`
     0.35 → 0.15–0.20 s.
3. This part is evidence-first: no code ships without a before/after trace
   showing the commit-block shrinking. If the evidence points somewhere new,
   stop and write it up in the research doc instead of speculating in code.

## Part E — Tile badge rework: video duration rules + RAW tag

**Files:** [Otos/Views/MediaAssetTileView.swift](../../Otos/Views/MediaAssetTileView.swift),
[Otos/Views/MediaAssetTilePresentation.swift](../../Otos/Views/MediaAssetTilePresentation.swift);
docs: `docs/requirements.md` APP-006, ADR 0006 (tile paragraph).

**Current behavior** (for orientation): `configureBadge(for:)`
(MediaAssetTileView.swift:115) shows the badge for any `bestKind == .video`
detail — duration text when known, else the film icon — including on
placeholder tiles, where it duplicates the centered film placeholder glyph.
`layoutVideoBadge()` (:202) hides the badge when the face is under 56 pt
(`showsVideoBadge(contentRect:)` — keep this size gate for all badge content).

**New behavior specification (goes verbatim into APP-006):**

| Tile state | Lower-right shaded badge |
| --- | --- |
| No thumbnail painted yet (placeholder), any kind | **none** (the centered placeholder glyph already communicates kind) |
| Thumbnail painted, video with known duration | duration text, **center-justified** in the shaded area |
| Thumbnail painted, video with unknown duration | film icon (in lieu of the length) |
| Thumbnail painted, raw image (`bestKind == .raw`) | the word `RAW`, center-justified, same shaded style |
| Thumbnail painted, plain image | none |

Data facts the implementer needs (verified 2026-07-09):

- `MediaTileDetail.bestKind` already distinguishes `.image` / `.raw` /
  `.video` (`MediaKind.classify` maps `UTType.rawImage` → `.raw` at scan
  time) and the tile-detail SQL already selects `best_kind` — **no schema,
  query, or model change needed** for the RAW tag.
- Duration (`duration_seconds`) and `thumbnail_path` are written by the same
  enrichment batch, so "thumbnail without duration" only occurs when duration
  extraction failed — the film-icon fallback is a rare-case affordance, per
  the owner.

Steps:

1. **Presentation policy first** (pure, testable —
   `MediaAssetTilePresentation`): introduce one badge-content value:

   ```swift
   nonisolated enum TileBadgeContent: Equatable {
       case none
       case durationText(String)
       case filmIcon
       case rawLabel
   }

   nonisolated static func badgeContent(
       detail: MediaTileDetail,
       thumbnailPainted: Bool
   ) -> TileBadgeContent
   ```

   Encode the table above. Keep `videoBadgeText(_:)` as the duration
   formatter it is today (or fold it in — one owner for the text either way).
2. **View renders the value** (`MediaAssetTileView`): `configureBadge` takes
   the computed `TileBadgeContent`; `render(_:change:)` recomputes it whenever
   detail *or* painted state changes — note `applyImage` and
   `updatePlaceholderPresentation` both flip `paintedImagePixelSize`, which
   now gates the badge, so badge configuration must follow paint-state
   changes, not just detail changes. Rename the `videoBadge` view and
   `layoutVideoBadge()` to kind-neutral names (`kindBadge`,
   `layoutKindBadge()`) — it now carries video and RAW content; reuse the
   existing shaded style, corner mask, and ≥ 56 pt face-size gate unchanged.
   The RAW label reuses `durationField`'s font/style (rename the field
   `badgeLabel`); the film icon stays `filmIconView`.
3. **Center the text.** Badge width stays
   `max(badgeMinWidth, ceil(textWidth) + 2 × badgeHorizontalPadding)`; the
   label frame must center the *actual* text within the badge for both the
   duration and `RAW` cases (today `videoBadgeDurationFrame` insets by the
   fixed padding — when the min-width clamp wins, the text is off-center;
   compute the label frame from the measured text width, centered, in
   `MediaAssetTileLayout`). Add layout tests for both the clamped and
   unclamped widths.
4. **Accessibility:** placeholder video tiles lose the badge but keep their
   existing labels; painted video with duration → `"Video, <length>"`;
   painted video without duration → `"Video"`; painted raw → `"RAW image"`.
5. **Reuse/monotonic paint interplay:** `clearLayerForReuse()` (:149) already
   hides all badge subviews — extend for the RAW label state, and re-derive
   badge content on the next `render` (the store's `TileContent` is the only
   input — no badge state may survive reuse).
6. **Tests** (`MediaAssetTilePresentationTests`, plus a thin view test if the
   existing harness supports it): the full table above, including the
   placeholder-video case (no badge), the no-duration video case (film icon),
   RAW with/without thumbnail, and text-centering geometry for short ("0:05")
   and long ("1:23:45") strings.
7. **Docs in the same PR:** APP-006 behavior text (badge table) and ADR 0006's
   tile paragraph ("Only content whose generated best kind is video gets a
   bottom-right badge…" — now video-or-raw, painted-only, with the
   centered-text and film-icon-fallback rules).

**Oracle:** this is a deliberate behavior change — presentation tests encode
the new table; APP-015/no-blank and selection tests stay green unmodified.

## Increment / PR breakdown

| PR | Contents | Oracle |
| --- | --- | --- |
| 1 | Parts A + B | Existing tests green unmodified + new gate/threshold tests; capture: `completionMs` single-digit, `diffPolicyMs` halved, `animationSuppressed=true` while scrolling, hang count down |
| 2 | Part C (fingerprint) behind its measurement gate; Part D spike evidence | Property tests; capture: `snapshotBuildMs+applyCallMs ≤ ~40 ms`, hash frames gone from hang windows — else drop Part C and record numbers |
| 3 | Part E (badges) | New presentation-table tests; APP-006/ADR 0006 updated in-PR |

Standard repo process per PR: dedicated worktree, conventional branch prefix,
`script/verify.sh` (Xcode 27), review-comment scan of the last five PRs, code
smells noted, docs updated in the same PR.

## Verification protocol (Parts A–D; repeat per PR, attach artifacts)

Same as plan 0008's: run against the OneDrive library while enrichment is
active (backlog was ~18.1k of 23,045 on 2026-07-09 — check
`SELECT COUNT(*), SUM(enriched_source_mtime IS NOT NULL) FROM media_asset;`),
`script/logs.sh stream` + 120 s `xctrace` SwiftUI-template attach while
scrolling continuously.

Baselines to beat (2026-07-09 post-plan-0008 run):

- 95 `mainThreadStall` faults in ~3 min of log; 31 hangs in 120 s of trace,
  worst 714 ms, including 9 back-to-back hangs in an 8 s hard-scroll stretch;
- per-apply: `applyMs` 128–166 (`diffPolicyMs` 27–65, `snapshotBuildMs` ~30,
  `applyCallMs` ~43, `completionMs` ~27) at ~26 applies/2 min.

**Done means:** zero Hangs-table entries during 60 s of continuous scrolling
with enrichment active, applies continuing at the full cadence, `applyMs`
< 50 ms end-to-end, and no regression in thumbnail arrival latency. (Slow
visible thumbnails on unenriched cloud files are a separate, known
materialization-latency fact — one visible RAW measured 50 s of OneDrive
download; out of scope here, candidate lever recorded in the roadmap idea
pile: viewport-priority download concurrency.)

## Explicit non-goals

- No cadence changes (projection 1 s, enrichment flush 1 s) — standing owner
  decision.
- No reloadData for same-descriptor reorders under any condition (Part B
  suppresses animation only).
- No snapshot-mutation/moveItem machinery, no LIS/mover computation.
- No materialization-concurrency change for slow cloud thumbnails (roadmap
  idea, needs its own owner decision).
- No new badge kinds beyond video duration/film-icon fallback and RAW.
