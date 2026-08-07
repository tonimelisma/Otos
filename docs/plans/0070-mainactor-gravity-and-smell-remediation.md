# 0070 — MainActor gravity and smell remediation (blank-slate)

## Context

PR #173 added loupe click-to-play video via `VideoPreviewLoader` holding `@MainActor AVPlayer` as `nonisolated(unsafe) @unchecked Sendable` inside an `actor` off MainActor. It passes checks but is MainActor gravity + unsafe escape + state duplication (loader `currentState` + ViewModel `loupeVideoState`). Repo default `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes future pure value types MainActor-isolated unless annotated, causing `id is MainActor-isolated` test traps. Lint reports 229 warnings (0 serious) with accepted `file_length` on `CatalogWindowViewModel.swift`. Research `docs/research/2026-08-07-mainactor-gravity-and-smells-research.md` evaluates bandaid (`@preconcurrency`, isolated box) vs blank-slate.

Goal: smallest correct ownership, no unsafe, one owner per question, no speculative abstraction.

## Decision

1. Make loupe video player lifecycle natively `@MainActor` (it is UI, like `AVPlayerView`), not an off-MainActor actor holding an unsafe MainActor object.
2. Make pure domain value types explicitly `nonisolated` so they survive default isolation without scattering `@MainActor` on tests.
3. Remove state duplication: ViewModel is the single published owner of loupe content; loader becomes stateless factory (or single-owned via ViewModel projection, not two mirrored optionals).

### What changes

**A. `Otos/Services/VideoPreviewLoader.swift`**

- Change `actor VideoPreviewLoader` → `@MainActor final class VideoPreviewLoader` (or `@MainActor actor` if actor semantics retained, but class is simpler: loupe play is userInitiated priority, single player, no need for actor reentrancy beyond MainActor serialisation).
- Remove `@unchecked Sendable` / `nonisolated(unsafe)` on `LoupeVideoState`.
- Change `struct LoupeVideoState: @unchecked Sendable, Equatable` → `@MainActor struct LoupeVideoState: Equatable` with normal `let player: AVPlayer`. Equality stays `player ===`.
- Remove `private var currentState: LoupeVideoState?` from loader; keep only `status` closure and `materializationRequester`. Alternatively keep single `currentState` inside loader and have ViewModel read `videoLoader.currentState` as computed published property — choose ViewModel single owner (see B). Removal eliminates duplication.
- Keep `func play(id:detail:) async -> LoupeVideoState?` but make it `nonisolated` for the materialize await or keep on MainActor: `async` on MainActor suspends correctly, so staying isolated is fine. Heavy 120s coordinator await frees MainActor at suspension. Internally, remove explicit `MainActor.run` around `AVPlayerItem`/`AVPlayer` — already on MainActor.
- `pauseAndCleanup` becomes synchronous `private func pauseAndCleanup(_ player: AVPlayer)` on MainActor (or takes `LoupeVideoState`).

**B. `Otos/ViewModels/CatalogWindowViewModel.swift` + `CatalogWindowViewModelViewMode.swift`**

- ViewModel already `@MainActor @Observable`, so loupe video state naturally lives there.
- Option B1 (preferred, stateless factory): keep `var loupeVideoState: LoupeVideoState?` on ViewModel as single source; `VideoPreviewLoader` has no `currentState`. `clearOnFocusChange` is removed; ViewModel’s `refreshPanePreviews` just does `if loupeVideoState?.id != focusedAssetID { loupeVideoState = nil }` and then `loupeVideoState?.player.pause()` (if needed) — no `await videoLoader.clear...`.
- Option B2: keep loader’s `currentState` as owner, make ViewModel’s `loupeVideoState` a computed `var loupeVideoState: LoupeVideoState? { videoLoader.currentState }` with helper to trigger `objectWillChange`. B1 is smaller; B keeps loader owned but requires Observable bridging. Choose B1 for minimal diff.
- `playLoupeVideo(id:)` simplifies: no `MainActor.run` hops (already on MainActor), just `guard let state = await videoLoader.play(...) else { downloadingSlots.remove(.loupe); return }` then `loupeVideoState = state; state.player.play()`.
- Remove `pauseLoupeVideo`/`clearLoupeVideo` Tasks with weak self + MainActor.run; replace with synchronous MainActor methods (ViewModel is MainActor, so `func pauseLoupeVideo() { loupeVideoState?.player.pause(); loupeVideoState?.player.replaceCurrentItem(with: nil); loupeVideoState = nil }` or delegate to loader’s synchronous cleanup.
- `refreshPanePreviews` Task hopping removed: becomes synchronous check (ViewModel is MainActor, no await needed except for pause if loader has async).

**C. Pure domain models — survive default MainActor**

- Annotate `MediaAssetID`, `MediaRelativePath`, `LibraryRootPath`, `PanePreview`, `BrowserViewMode`, `ComparePair`, etc. as `nonisolated struct` / `nonisolated enum` where they are pure Sendable data. Top of each file: add `nonisolated` to type declaration, or file-level `nonisolated` extension. This prevents future `Equatable` + default isolation trap and lets tests stay non-MainActor.

Minimum set for this increment: `Otos/Models/CatalogModels.swift` (MediaAssetID, MediaRelativePath, LibraryRootPath, MediaTileDetail, PanePreview), `Otos/Models/PanePreview.swift`, `Otos/Models/BrowserViewMode.swift`, and `Otos/Services/VideoPreviewLoader.swift: LoupeVideoState` (make it MainActor explicitly, id still accessible off MainActor via nonisolated? Actually if LoupeVideoState is @MainActor, its id is MainActor-isolated; tests that assert on id must be @MainActor — keep tests @MainActor as already fixed, or split id into Sendable part: better to keep LoupeVideoState @MainActor and keep tests @MainActor).

Alternative minimal: leave models as-is and keep tests `@MainActor` — but blank-slate says annotate models now so next increment doesn’t repeat trap.

Chosen: annotate models in this plan; touch 3–4 files, small diff, removes why-next-file-needs-workaround tax.

**D. Lint smells**

- `VideoPreviewLoaderTests.swift:71 var n` → rename to `count` or `sequenceIndex` to clear `identifier_name` warning; same for `MaterializationCoordinatorProviderBreakerTests` `n`.
- Do not split `CatalogWindowViewModel.swift` for `file_length`; keep cohesion per AGENTS.md. Record acceptance in PR description (“catalogWindowViewModel file_length warning accepted”).

### What does not change

- `PreviewImageLoader` stays `actor` off MainActor (CGImage not MainActor). Correct separation: image decode off MainActor, video player on MainActor.
- `CatalogStore`/`CatalogProjection` actors off MainActor.
- `LoupeVideoPlayerView` remains passive NSViewRepresentable.
- No new protocols, caches, or queues.

## Acceptance

- `grep -rn "nonisolated(unsafe).*AVPlayer\|@unchecked Sendable.*LoupeVideoState"` returns 0.
- `script/verify.sh` green (590 passed, 1 skipped, production-data-untouched clean).
- `script/lint.sh` 0 serious (file_length on CatalogWindowViewModel accepted, no new identifier_name on video files).
- `script/build.sh` BUILD SUCCEEDED.
- `script/ci-text-hygiene.sh check` and `script/requirements-authority-check.sh` clean.
- No `MainActor.run` required inside VideoPreviewLoader (already MainActor); ViewModel hopping reduced.
- `PanePresentation.display` video case remains identity-guarded; compare stays poster-only.

## Verification

1. `xcodebuild -version` (Xcode 27.0) + `script/verify.sh` full output.
2. `script/lint.sh` before/after diff — serious delta 0.
3. `grep` for unsafe AVPlayer absence.
4. Existing tests `VideoPreviewLoaderTests`/`LoupeVideoPlayerTests` green without `@preconcurrency`.
5. Manual code review: single owner for loupe video (ViewModel `loupeVideoState`, loader stateless), vs previous double.

## Ownership check

- Player lifecycle: ViewModel (published loupeVideoState) + factory loader (or Loader-owned if class) — one owner, not two.
- Display identity: PanePresentation owns display decision.
- Chrome: LoupeVideoPlayerView owns AVPlayerView config.
- Materialization: MaterializationCoordinator owns bounded scheduler.

## Risks

- Moving loader to MainActor could be seen as “gravity worsened”, but player is inherently MainActor UI object; this aligns with SDK and approachable concurrency intent. Heavy await frees MainActor, so no jank.
- Annotating models `nonisolated` touches 3–4 files; risk is forgetting one — verify with `grep "struct PanePreview\|struct MediaAssetID"` and ensure nonisolated.
- No ADR needed beyond update to existing ADR 0016 notes; plan docs current truth.
