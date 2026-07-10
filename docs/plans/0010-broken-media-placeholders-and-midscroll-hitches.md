# Plan 0010: Broken-Media Placeholders (No Icon Fallback) + Mid-Scroll Hitch Residuals

Status: active. Delete this file when all parts have landed on `main`.

Owner evidence:
`docs/research/tile-placeholder-and-broken-media-iconography.md` (root cause of
the document-icon tiles, SF Symbol availability, HIG grammar) and the
"Mid-scroll residual analysis" section of
`docs/research/grid-reorder-cadence-and-appkit-diffable-apply.md` (hitch-window
stack composition from `build/Profiles/SwiftUI-plan0009-20260709-191352.trace`).

## Owner decisions captured (2026-07-09)

- **Never store QuickLook's icon fallback as a thumbnail.** If a real
  thumbnail cannot be generated, the generation should error out and the tile
  should show a broken-media placeholder. ("I hate to get a generic icon
  thumbnail instead of the real deal.")
- **No repair/migration for already-stored icon thumbnails** — the catalog
  database gets nuked and rebuilt anyway (it is a rebuildable projection).
- **All mid-scroll levers approved**: defer apply adoption during live scroll,
  IOSurface-friendly decodes, observability gating + a Release-build capture,
  duration-string caching + mutate-on-change badges, `GridSelection.pruned`
  skip on empty selection.
- Broken tiles show **no lower-right kind badge** (video/RAW tags are for
  loaded media only). Loading-RAW gets its own glyph.
- Standing decisions unchanged: once-per-second reorder cadence; never
  reintroduce the reloadData teardown for same-descriptor reorders.

## Invariants (do not regress)

- **APP-015 no-blank**: a *painted* same-asset thumbnail never regresses to
  placeholder content. The broken-media placeholder is only ever shown for
  assets that have **no stored thumbnail** — it never replaces painted pixels.
  `MediaGridPaintInvariantTests` / `TileContentStoreTests` stay green
  **unmodified**.
- One implementation path (projection → ViewModel → bridge → gate →
  controller); publication cadence untouched.
- Enrichment staleness stays purely `(size, mtime)` (ENR-007): a broken file
  is stamped enriched-with-no-thumbnail and is **not** retried until the file
  changes on disk. That is desired (0-byte toy-camera stubs never churn).
- Every performance part ships with before/after capture evidence.

---

## Part A — Error out instead of icon fallback

**Files:** [Otos/Services/MediaEnricher.swift](../../Otos/Services/MediaEnricher.swift),
[Otos/Models/CatalogModels.swift](../../Otos/Models/CatalogModels.swift);
docs: `docs/requirements.md` ENR-004, ADR 0009.

Verified API semantics (macOS 27 SDK, `QLThumbnailGenerationRequest.h`):
`representationTypes` is an allowlist of "desired successive representations …
generated when possible". Without `.icon` in the set,
`generateBestRepresentation` **throws** when no real thumbnail can be
produced. The enricher's `catch` path already returns `nil` and still records
definitive metadata + the enrichment stamp.

1. In `generateThumbnail` (MediaEnricher.swift:83–88), change
   `representationTypes: [.thumbnail, .lowQualityThumbnail, .icon]` to
   `[.thumbnail, .lowQualityThumbnail]`. Keep `.lowQualityThumbnail`: it is
   real imagery (QuickLook-cached), not a generic icon.
2. Rewrite the function's doc comment (it currently says "Accepts QuickLook's
   icon fallback (a generic tile beats none)") to state the new policy: a
   generation failure is a definitive "no thumbnail available" outcome.
3. Upgrade the failure log (MediaEnricher.swift:107–109) to a structured,
   greppable line including the error:
   `OtosLog.thumbnails.errorOperation("catalog.thumbnails.generate", phase: "unavailable", fields: ["path": …, "error": String(describing: error)])`
   — today's diagnosis was blind precisely because icon fallback logged as
   success.
4. **The stored fact is derived, not new schema**: an asset with the
   enrichment stamp present (`enriched_source_mtime` non-NULL) and
   `thumbnail_path` NULL has no obtainable thumbnail. Add one derivation point
   on `MediaTileDetail`:

   ```swift
   /// Enrichment ran and could not produce a real thumbnail (icon fallback is
   /// never stored). Distinguishes "broken/unsupported media" from "not yet
   /// enriched" (both have thumbnailPath == nil).
   var thumbnailUnavailable: Bool {
       enrichedSourceMTimeSeconds != nil && thumbnailPath == nil
   }
   ```

   The tile-detail SQL already selects both columns — no query change.
5. Docs in the same PR: ENR-004 currently says "generated from QuickLook with
   its icon fallback accepted" — rewrite to "icon fallback rejected; a
   definitive-but-thumbnail-less outcome stamps the asset and the grid renders
   a broken-media placeholder". Update ADR 0009's corresponding sentence. No
   catalog migration: the database is nuked/rebuilt (owner decision), and the
   schema is unchanged anyway.

**Oracle:** existing enrichment tests green (the nil path already exists);
add/extend a test asserting a failed generation still stamps the asset
(definitive outcome, no retry churn) if not already covered by
`CatalogStoreEnrichmentTests`.

## Part B — Broken-media placeholders and badge suppression

**Files:** [Otos/Views/MediaAssetTilePresentation.swift](../../Otos/Views/MediaAssetTilePresentation.swift),
[Otos/Views/MediaAssetTileView.swift](../../Otos/Views/MediaAssetTileView.swift);
docs: `docs/requirements.md` APP-006, ADR 0006.

Glyph set (availability verified on this machine; HIG slash grammar =
"unavailable" — see research doc):

| Tile state | Center glyph (same dim placeholder family) | Lower-right badge |
| --- | --- | --- |
| Not yet enriched, image | `photo` | none |
| Not yet enriched, RAW | `r.square` (NEW — differentiates RAW) | none |
| Not yet enriched, video | `film` | none |
| Thumbnail unavailable (broken), image **and RAW** | `photo.slash` | **none** |
| Thumbnail unavailable (broken), video | `video.slash` | **none** |
| Thumbnail painted | (thumbnail) | per plan 0009 Part E rules |

Broken-RAW shares `photo.slash`: no `r.square.slash`/`raw` symbol exists; a
composited glyph was considered and rejected for simplicity (the RAW corner
tag disappears on broken tiles anyway, and brokenness is the fact that
matters). If the owner wants strict broken-RAW differentiation later, the
composition option is recorded in the research doc.

1. Extend `placeholderIconSystemName(for:)`
   (MediaAssetTilePresentation.swift:114) to take the broken fact:
   `placeholderIconSystemName(for kind: MediaKind?, thumbnailUnavailable: Bool)`
   returning the table above (`.raw` → `r.square` when loading). The existing
   name-keyed `placeholderIcon(for:)` cache already handles arbitrary names —
   thread the new parameter through.
2. `MediaAssetTileView.updatePlaceholderPresentation()` passes
   `content.detail.thumbnailUnavailable`; keep the identical dim styling,
   sizing policy, and change-guard (`appliedPlaceholderIconName`) so broken
   and loading placeholders read as siblings.
3. Badge suppression: in `badgeContent(detail:thumbnailPainted:)` (plan 0009
   Part E), return `.none` whenever `detail.thumbnailUnavailable` — a video
   we could not load shows no duration/film corner tag, a RAW we could not
   load shows no RAW tag. (Structurally this mostly falls out of
   `thumbnailPainted == false`, but encode the explicit rule + test so a
   future "paint something else" change cannot resurrect badges on broken
   tiles.)
4. Accessibility: broken image/RAW → `"Image unavailable"`, broken video →
   `"Video unavailable"`.
5. Docs: APP-006 gains the table above (two broken rows + the RAW loading
   glyph); ADR 0006's placeholder paragraph updated (dim media-kind icon →
   the five-state glyph table; no spinner/shimmer rule unchanged).

**Oracle:** presentation-table tests extended for every row above, including
the badge-suppression-on-broken rule and the r.square loading state. Paint
invariant tests unmodified.

**Verification note (agent-owned):** after the owner nukes the catalog and
the toy-camera library rescans/enriches, the 0-byte AVI/JPG tiles must log
`catalog.thumbnails.generate phase=unavailable` and render slash placeholders
with no badge. Until the nuke happens, unit tests carry the proof (existing
icon-thumbnails on disk are stale rows the owner is deleting anyway).

## Part C — Defer structural-apply adoption during live scroll

**Files:** [Otos/Views/MediaGridMutationGate.swift](../../Otos/Views/MediaGridMutationGate.swift),
[Otos/Views/MediaGridBridge.swift](../../Otos/Views/MediaGridBridge.swift)

Evidence: apply-adjacent work (`applySnapshot`, gate completion, snapshot
build, `GridSelection.pruned`) plus the commit each apply provokes all appear
inside the ≥100 ms hitch windows even with suppressed animation. An apply
adopted mid-fling buys nothing visually.

Design (single owner, no timers in the gate):

1. Gate gains an explicit hold:

   ```swift
   private(set) var scrollHold = false
   func beginScrollHold()          // controller: on scroll tick
   func endScrollHold() -> [Action] // controller: on quiet; drains parked work
   ```

   While `scrollHold` is true, `receive(_:)` parks grids as `pendingGrid`
   (newest-wins, exactly like the in-flight case) **except**
   descriptor-changed grids, which bypass the hold (a user just changed
   sort/scope/filter; they expect the reset immediately, and those applies
   reset scroll anyway).
2. Controller wiring reuses the existing scroll machinery: `scrollBoundsChanged`
   calls `beginScrollHold()`; a coalesced quiet task (cancel/restart on each
   tick, fire after the same 250 ms threshold Part B of plan 0009 uses —
   share the constant) calls `perform(gate.endScrollHold())`. No new
   notification observers.
3. Diagnostics: gate stall fields gain `scrollHold`; the structural-apply
   finish line is unchanged (held grids simply apply a moment later); add a
   `heldDuringScroll=true/false` field on the apply for capture correlation.
4. Interaction with `inFlight`: hold and in-flight compose — `drain()` runs
   only when both are clear. Write the state-machine tests first:
   hold→receive→release drains newest; hold + descriptor-change applies
   immediately; hold during in-flight apply keeps newest-wins; zoom swaps are
   unaffected by hold (zoom is a user intent).

**Oracle:** gate unit tests for the truth table above; existing gate tests
green (amended only where the action shape requires); capture shows zero
structural applies inside sustained-scroll windows and immediate adoption on
quiet (≤ ~300 ms after last tick).

## Part D — IOSurface-friendly thumbnail decode

**Files:** [Otos/Services/ThumbnailStore.swift](../../Otos/Services/ThumbnailStore.swift)
(the decode used by store-miss loads and preheat)

Evidence: `CVPixelBufferBacking::performStandardMemoryLayoutAndCopyIOSurface…`
inside `CA::Transaction::commit` in every hitch analysis — CA copies each
CGImage into an IOSurface at commit time because the decoded bitmaps are not
in a CA-friendly format.

1. In the decode path, draw the decoded image once into a
   premultiplied-BGRA bitmap context
   (`kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little`, device RGB)
   at the thumbnail's pixel size and hand that context's `makeImage()` to the
   store. One extra draw per decode (off-main, bounded 256 px) in exchange
   for copy-free commits on every subsequent paint of that image.
2. Measure, don't assume: before/after trace comparing the
   `CVPixelBufferBacking` slice inside hitch windows. If the copies do not
   shrink, revert and record the numbers in the research doc — the format
   theory is plausible but unproven on this OS.

**Oracle:** paint invariant/decode tests unmodified (the image is still a
`CGImage`; `TileContentStore.byteCost` still correct); trace evidence
attached.

## Part E — Observability cost gating + a Release-build capture

**Files:** [Otos/Views/MediaGridBridge.swift](../../Otos/Views/MediaGridBridge.swift),
[Otos/Support/Instrumentation.swift](../../Otos/Support/Instrumentation.swift)
(only if a shared toggle helper is added)

Evidence: ~107 ms of signpost/OSLog emission inside the 43 worst hitch
windows — instrumentation itself is a measurable scroll-path cost in Debug
runs (which is how the owner runs the app day-to-day).

1. Keep (always on): the 1 s summary lines (`scrollBounds phase=window`,
   `reconfigure phase=finish`, `structuralApply phase=finish`, projection and
   enrichment op lines) — the agent's diagnosis depends on them.
2. Gate (default off): per-flush/per-item debug chatter and per-flush
   signpost intervals on the scroll path (`MediaGridVisibleReconfigure` /
   `MediaGridVisibleDetailQuery` intervals, per-query debug lines, per-item
   fade/render logs). One static
   `let uiVerbose = ProcessInfo.processInfo.environment["OTOS_UI_VERBOSE"] == "1"`
   checked at emission sites — no new abstraction layer.
3. Capture once with `-configuration Release` (build_and_run builds Debug;
   a one-off `xcodebuild … -configuration Release` + attach is fine) and
   record Debug-vs-Release hitch tails in the research doc, so future "feels
   choppy" reports are judged against the build type the user actually ships.

**Oracle:** `script/verify.sh` green; a Debug capture with `OTOS_UI_VERBOSE`
unset shows the summary lines still present and the per-flush chatter gone.

## Part F — Bind-path micro-costs

**Files:** [Otos/Views/TileContentStore.swift](../../Otos/Views/TileContentStore.swift),
[Otos/Views/MediaAssetTilePresentation.swift](../../Otos/Views/MediaAssetTilePresentation.swift),
[Otos/Views/MediaAssetTileView.swift](../../Otos/Views/MediaAssetTileView.swift),
[Otos/Views/MediaGridStructuralApply.swift](../../Otos/Views/MediaGridStructuralApply.swift)

1. **Cache the formatted duration.** `videoBadgeText` runs
   `Duration.formatted(...)` on every bind (~31 ms in hitch windows). Compute
   it once when detail merges (`TileContent` gains `formattedDuration:
   String?`, set in `TileContentStore.mergeDetail` when `durationSeconds`
   changes); the view consumes the cached string. When the separate
   MediaMetadata work lands AVI durations, this cache picks them up through
   the same merge path — no coordination needed beyond that.
2. **Mutate badge subviews only on change.** Track the last-applied
   `TileBadgeContent` (mirror of `appliedPlaceholderIconName`); skip
   show/hide/frame churn when unchanged (`_NSViewSubViewMutationSafeApply`
   appears in commit stacks).
3. **Skip `GridSelection.pruned` when the selection is empty**
   (`GridSelection.pruned` ~40 ms across hitch windows; the common case
   scrolls with nothing selected).

**Oracle:** behavior-preserving; existing tile/selection tests green
unmodified; new unit test for the cached duration invalidation (duration
change → new string; unrelated detail change → same instance).

## Increment / PR breakdown

| PR | Contents | Oracle |
| --- | --- | --- |
| 1 | Parts A + B (no-icon policy, broken placeholders, badge suppression) + ENR-004/ADR 0009/APP-006/ADR 0006 | Presentation-table + enrichment-outcome tests; paint-invariant tests unmodified |
| 2 | Part C (scroll-hold gate) | Gate truth-table tests; capture: no applies inside sustained scroll, adoption ≤ ~300 ms after quiet |
| 3 | Parts D + E + F (render/observability/bind perf) | Trace evidence for D (CVPixelBuffer slice) and E (verbose-off chatter gone); F unit tests; Release capture recorded |

Standard repo process per PR: dedicated worktree, conventional branch prefix,
`script/verify.sh` (Xcode 27), review-comment scan of the last five PRs, code
smells noted, docs updated in the same PR.

## Verification protocol (repeat per perf PR, attach artifacts)

Capture flow as plans 0008/0009: enrichment active, `script/logs.sh stream`,
120 s `xctrace` SwiftUI-template attach, continuous scrolling.

Baselines to beat (plan-0009 final run, Debug build):

- Instruments Hangs table: **0 rows — must stay 0**;
- hitches: 1,718 total / 43 ≥ 100 ms / p99 192 ms / worst 441 ms in 120 s;
- per-apply: `applyMs` 63–68 (suppressed) with `diffPolicyMs` 8–10,
  `snapshotBuildMs` 16–19, `completionMs` 10–11.

**Done means:** hangs stay at zero; the ≥100 ms hitch count and p99 drop
materially during sustained scroll (target: single-digit ≥100 ms hitches per
120 s in Debug; record Release numbers alongside); no structural applies
inside sustained-scroll windows; broken-media tests green; thumbnail arrival
latency unregressed.

## Explicit non-goals

- No AVI/duration metadata extraction — a separate MediaMetadata work stream
  owns that; this plan only ensures the badge/cache pick its results up
  automatically post-rebuild.
- No catalog repair/migration for already-stored icon thumbnails (owner nukes
  the database).
- No zero-byte scanner special-casing — the QuickLook error path covers all
  breakage shapes with one mechanism.
- No materialization-concurrency change (roadmap), no cadence changes, no
  reloadData for same-descriptor reorders.
