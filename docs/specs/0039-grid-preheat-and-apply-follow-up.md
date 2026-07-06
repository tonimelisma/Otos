# Spec 0039: Grid Preheat And Apply Follow-Up

## Status

Implemented in this increment.

## Classification

Bug fix, rendering architecture, performance/instrumentation, and documentation
correction.

## Problem Statement And User-Facing Goal

The post-implementation review of spec 0038 found that the no-blank grid
invariant was structurally correct but two performance paths still fought it:
manual preheating did one Store/SQLite detail read per item, and large
zero-duration diffable applies had been measured at multi-second wall times in a
real session. The user-facing goal is that the grid keeps the no-blank thumbnail
behavior while reducing unnecessary Store pressure, avoiding measured multi-second
AppKit applies, and keeping diagnostics truthful about what the app is defending.

## Captured Requirements For Verification

The user asked to fix every finding in the attached implementation review. I
restated the requirements back before implementing: F1 and F2 are the major
performance findings; F3 and F5 are local code-smell fixes; F4, F6, and F7 need
documentation or evidence so the current behavior is not overstated. Captured
current requirements:

- Functional: prefetch and manual look-ahead shall coalesce each burst into one
  `MediaTileDetailReader.assets(for:)` call, with newer bursts cancelling older
  bursts.
- Non-functional: decoded-thumbnail cache hits and inserts shall be callable
  off-main so decode-side warming does not add a main-actor hop.
- Non-functional: large and reorder-only structural applies shall use the
  measured reloadData-class diffable fallback while small/user-visible changes
  may animate.
- Architecture: the reloadData fallback is permitted only because APP-015's
  synchronous paint and same-identity guards make recycled visible tiles repaint
  safely.
- Tooling: structural-apply diagnostics shall record `reloadDataFallback`
  instead of the retired `zeroDuration` field.
- Regression: the sticky detail cache shall keep least-recently-used semantics
  without an O(limit) recency scan on every hit.
- Regression: `applyImage` shall not clear `NSImageView.image` before assigning
  layer contents; the tile's layer contents are the rendering surface.
- Process: docs shall record that AppKit prefetch is opportunistic: the review
  evidence saw only one callback, while the post-fix smoke run saw callbacks but
  still did not make them required for correctness.
- Process: docs shall record that `MediaTilePaintInvariantViolation` means a
  same-asset clear was blocked, not proof that the user saw a visible blank.
- Process: the overlay-corner mask orientation shall be checked with screenshot
  evidence when the app can be captured.

## Current Repo State

Inspection before implementation found:

- `MediaAssetCollectionPrefetch` started one detached task per ID and each task
  called `assets(for: [id])`.
- `MediaTileImageCache` was `@MainActor`, so preheater and decode-task cache
  inserts hopped to the main actor.
- `MediaTileDetailCache.markRecent` used `recency.removeAll` on each merge or
  lookup.
- `MediaGridStructuralApplyPolicy` still encoded duration-zero true diffing for
  large/reorder applies, and docs/tests asserted that behavior as current truth.
- `MediaAssetTileView.applyImage` still set `imageView.image = nil` even though
  tile painting uses `imageView.layer?.contents`; spec 0040 removed that
  vestigial clear.
- Spec 0038 and ADR 0006 described zero-duration diffable applies as the current
  selected path and only listed reloadData as a future fallback.
- The review evidence reported AppKit prefetch as effectively inert in its smoke
  run and reported multi-second apply times in a live session.

## In Scope

- Batch preheat/detail reads and make preheating newest-burst-wins.
- Make the decoded-image cache non-main-actor isolated and thread-safe.
- Replace sticky-detail recency array scans with access stamps.
- Switch large/reorder structural applies to the reloadData-class fallback and
  rename diagnostics from `zeroDuration` to `reloadDataFallback`.
- Remove the vestigial image clear in `applyImage`.
- Update specs, ADR 0006, requirements, onboarding, indexes, source-hygiene tests,
  and affected file guides/comments.
- Run local build/test verification plus smoke/screenshot evidence where the
  agent environment permits.

## Out Of Scope

- Changing projection cadence, reorder production, enrichment scheduling, or
  thumbnail storage.
- Adding a custom collection renderer or a new AppKit abstraction.
- Persisting cache or preheat state.
- Changing overlay layout dimensions beyond documenting screenshot verification
  for the already-implemented 0038 geometry.

## Linked Current Requirement IDs

FND-041, FND-044, FND-046, APP-006, APP-015, ENR-002, ENR-004, and ENR-010.

## Architectural Alternatives

### Alternative A: Keep Zero-Duration True Diffing And Only Batch Preheat

Pros: preserves the 0038 selected apply path and avoids AppKit reloadData-class
recycling. Cons: ignores measured 5.1 s and 25.2 s apply spans, keeping a
MainActor responsiveness problem in place. Failure mode: the app remains visually
correct but stalls badly enough that the grid feels broken.

### Alternative B: Debounce Or Slow Reorder Publication

Pros: reduces the number of expensive applies. Cons: changes Projection cadence
and hides the measured AppKit apply cost behind timing policy rather than fixing
the current rendering boundary. Failure mode: enrichment can still trigger one
large expensive apply, and freshness semantics get harder to reason about.

### Alternative C: Use ReloadData-Class Applies For Large/Reorder Changes

Pros: directly avoids measured multi-second true-diff apply work; keeps small
user-visible changes animated; remains visually safe because APP-015 already
forces synchronous decoded repaint and same-asset downgrade guards. Cons: AppKit
may recycle visible items more often, so cache coverage and tile paint guards are
mandatory. Failure mode: if the cache does not contain a previously painted key,
the tile may legitimately show placeholder for an asset never decoded in this
process, which APP-015 permits.

### Alternative D: Build A Custom Tiler

Pros: maximum control over reuse, preheat, and structural updates. Cons:
reimplements scrolling, accessibility, selection, and layout before evidence
proves `NSCollectionView` is insufficient. Failure mode: broad new surface area
and more bugs than the current narrow AppKit boundary.

## Selected Approach

Choose Alternative C, plus the F1/F3/F5 cleanup. The measured live session made
zero-duration true diffing too expensive for large/reorder applies. The reloadData
fallback is now the simplest correct path because the no-blank invariant moved
correctness to the tile: decoded cache hits paint synchronously, nil loads do not
clear a same-asset image, and missing detail rows are treated as information loss.
No additional cache, queue, schema, or projection layer is introduced.

## Interfaces, Ownership, Data Flow, And Persistence

- `MediaAssetCollectionViewController` owns one `preheatTask`, one
  `preheatGeneration`, and the current burst's ID set. New bursts cancel the
  previous task.
- `MediaTileDetailReader` remains the only Store-backed detail-read interface.
  A burst calls `assets(for: ids)` once.
- `MediaTileImageCache` remains ViewModel-owned rendering state. It is now a
  nonisolated, `Mutex`-protected `Sendable` class with cost/count LRU eviction.
- `MediaTileDetailCache` remains MainActor controller state; it now uses access
  stamps for LRU eviction.
- Structural diagnostics continue to record one JSONL aggregate per completed
  apply, now with `reloadDataFallback`.
- No persistence changes. No user media files are read beyond existing app-owned
  thumbnail decode paths, and no originals are written.

## Concurrency And Actor Ownership

- UI state, AppKit collection view state, and sticky tile details stay on the
  MainActor.
- Preheat work runs in one detached utility task per newest burst. It leaves the
  main actor for Store detail read and thumbnail decode, then briefly returns to
  the MainActor to merge details if the generation is still current.
- Cache lookup and insert are synchronous, thread-safe, and non-main-actor.
- Cancellation is newest-burst-wins for preheat; structural applies keep the
  existing apply-gate semantics of one apply in flight and one newest pending
  grid state.

## Instrumentation And Profiling Plan

- Unified logging/signposts continue to cover prefetch request/cancel, manual
  preheat request, image cache hit/miss/insert, structural apply start/finish,
  and cell configuration.
- JSONL structural apply diagnostics record `animatingDifferences`,
  `reloadDataFallback`, `preheatCount`, and `applyMs`.
- Verification shall include local `script/verify.sh` and a seeded smoke run when
  available. The smoke report should inspect apply duration, preheat behavior,
  watchdog count, and screenshot evidence for overlay mask orientation.

## Test And Acceptance Criteria

- Source hygiene proves preheat uses `detailReader.assets(for: ids)` and no
  per-ID preheat task loop remains.
- Policy tests prove small inserts animate, while large/reorder applies use
  reloadData fallback.
- Sticky detail cache tests still prove LRU behavior after the stamp rewrite.
- Source hygiene proves structural JSONL records `reloadDataFallback`.
- `script/verify.sh` passes with Xcode 27 beta.
- Smoke/screenshot verification records whether AppKit prefetch fires, whether
  watchdog events are zero or only defended attempts, and whether overlay masks
  match the intended visible corners.

## Stale Document And Comment Audit

Affected current docs: this spec, spec 0038, ADR 0006, requirements, onboarding,
and docs index. Non-authoritative planning/research docs with old zero-duration
wording are updated or marked stale where they claim current behavior. Affected
file guides: `MediaAssetCollectionView`, `MediaAssetCollectionPrefetch`, and
`MediaTileImageCache`; each now describes the current owner boundary.

## Code-Smell Review

- MainActor gravity: addressed by making `MediaTileImageCache` nonisolated and
  lock-backed.
- State duplication: none introduced; preheat state has one task/generation owner.
- Test coupling: accepted narrowly in source-hygiene tests because the behavior is
  an architectural source invariant.
- Diagnostic payload sprawl: none observed; only scalar counts/booleans are added.
- Stringly typed diagnostics: accepted because existing JSONL diagnostics use
  string fields consistently.

## Media Originals And Diagnostics Review

This increment reads app-owned thumbnail files for cache warming and writes no
originals, sidecars, or user media folders. Diagnostics contain only scalar
operation fields and bounded paths already allowed by the repo's developer-log
policy; no secrets, thumbnails, binary payloads, or metadata blobs are logged.
