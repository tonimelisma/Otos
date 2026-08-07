# 2026-08-07 — MainActor gravity and smell research

Sources: Apple Dev docs via `script/apple-docs.sh` (sosumi.ai), Swift Evolution, Swift Forums, first-party WWDC/approachable concurrency vision, Donny Wals, SwiftLint/SwiftFormat config, and direct repo audit. No originals read beyond project files.

## 1. What AGENTS.md calls a smell

AGENTS.md Code Smells (indicators, not guilt):

- MainActor gravity (work isolated to main because convenient)
- SwiftUI body work (scanning/decoding/sorting/I/O in `body` or sync `.task`)
- State duplication (two owners answer same domain question)
- AppKit bridge sprawl
- Unsafe concurrency escape (unchecked Sendable, detached tasks, shared mutable across actors)
- Stringly-typed domain facts, ambiguous API names, test coupling, diagnostic sprawl

Every PR must note `None observed` when true. This research inventories current.

## 2. Otos current isolation baseline

`Otos.xcodeproj/project.pbxproj`:

- `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
- `SWIFT_STRICT_CONCURRENCY = complete`

This is Swift 6.2 / Xcode 26 “Approachable Concurrency”:

- Vision: `swift-evolution/visions/approachable-concurrency.md` — “keep things simple and avoid a lot of concurrency headaches by defaulting to using the main actor; only moving work off when measured” (forums summarise 2025-06).
- Implementation: `-default-isolation MainActor` makes every type/function default to `@MainActor` unless annotated `nonisolated` (or `nonisolated(nonsending)` in 6.2). Forums: “Default MainActor isolation acts as if you’d typed @MainActor on everything, so instead of having to add MainActor to things you want isolated, you have to add nonisolated to things you don’t” (Jon Shier 2025-09-06, insight-needed-for-equatable thread).
- Otos comment in `docs/adr/0004-catalog-ui-ownership.md`: “Sorting, filtering … must stay off MainActor. Views must not coordinate catalog notifications…” — existing ownership already respects this; CatalogStore/CatalogProjection are actors off MainActor, TileContentStore/bridge correctly hop.

Forum thread `default-actor-isolation-mainactor-conflicts-with-sendable` (2026-06-29, eskimo): “A sendable struct without actor annotation will be stuck to MainActor” when default is MainActor — exactly LoupeVideoState case.

Donny Wals `setting-default-actor-isolation-in-xcode-26` (2025): “MainActor and nonisolated are only two valid values… nonisolated(nonsending) lets nonisolated sync functions inherit calling actor’s isolation instead of global executor.” Not needed for Otos yet, but relevant if we keep value types off MainActor.

## 3. AVFoundation @MainActor change (macOS 27 SDK)

- `AVPlayer`, `AVPlayerItem`, `AVPlayerView` are `@MainActor` in macOS 27 SDK (verified via build error 2026-08-06: `actor-isolated property 'timeObserver' can not be referenced from the main actor` and `instance method 'play()' is not available due to missing import` fixed by `import AVFoundation` + `nonisolated(unsafe)`).
- Prior SDKs: AVPlayer was not MainActor-isolated. Otos bandaid `struct LoupeVideoState: @unchecked Sendable, nonisolated(unsafe) let player: AVPlayer` was introduced to keep `VideoPreviewLoader` as `actor` off MainActor while holding a MainActor object. Equality compared `player ===`.
- Alternative annotations: `@preconcurrency import AVFoundation` would downgrade imported isolation to warnings (proposal 0423 `dynamic-actor-isolation`), but hides the signal.
- Blog `sergey-pekar nonisolated nonsending vs concurrent` Julien 2026-07 notes caller on MainActor when default isolation is MainActor — thread diagrams confirm suspend points do not block main thread even when awaiting.

## 4. Repo audit: MainActor gravity and other smells

### 4.1 MainActor gravity — VideoPreviewLoader (primary)

Files:

- `Otos/Services/VideoPreviewLoader.swift:21 actor VideoPreviewLoader` holding `nonisolated(unsafe) AVPlayer`
- `Otos/Services/VideoPreviewLoader.swift:133 struct LoupeVideoState: @unchecked Sendable`
- `Otos/ViewModels/CatalogWindowViewModelViewMode.swift:321 func playLoupeVideo` with 4 `MainActor.run` hops and `Task { [weak self] }`

Evidence of gravity:

- `grep @MainActor|MainActor.run|nonisolated\(unsafe\)` shows VideoPreviewLoader is only place in Otos that stores a MainActor object off MainActor via unsafe. PreviewImageLoader (CGImage) stays off MainActor correctly because CGImage is not MainActor-isolated.
- Duplication: `VideoPreviewLoader.currentState` and `CatalogWindowViewModel.loupeVideoState` both store `LoupeVideoState?`. Teardown requires `clearOnFocusChange` + MainActor `loupeVideoState = nil` in synchrony. Two owners answer “which video is playing” — violates one-owner-per-question.
- MainActor.run hopping inside actor: actor creates `AVPlayerItem(url:)` on `MainActor.run`, then `pauseAndCleanup` hops again. All player touch must be MainActor, so actor is serialising something that is inherently MainActor.

Severity: medium. Not a crash today (unsafe is correctly gated), but defeats Swift 6 complete checking and hides future actor reentrancy bugs.

### 4.2 MainActor gravity — domain models becoming MainActor by default

With default MainActor, any new `Equatable`/`Hashable` struct without `nonisolated` is MainActor-isolated. LoupeVideoState triggered `main actor-isolated property 'id' cannot be accessed from outside of the actor` in tests, fixed by marking tests `@MainActor`. PanePreview avoids this because it holds `CGImage` (not MainActor), so test not affected. But future structs (e.g., new preview state) will same-trap.

Evidence: build failure `VideoPreviewLoaderTests.swift:44` and `LoupeVideoPlayerTests` diff.

Severity: low-medium. Ongoing tax; new files must remember `nonisolated`.

### 4.3 State duplication (second confirmed smell)

- `CatalogWindowViewModel.previewLoader` (any PreviewLoading) + `VideoPreviewLoader` both submit `MaterializationCoordinator.Request` with `priority: .interactive` — correct single scheduler, but ViewModel also tracks `downloadingSlots: Set<PaneSlot>` while loader tracks nothing for video downloading beyond isMaterialized check. For video, `downloadingSlots.insert(.loupe)` is set optimistically before await, cleared on nil; for image, downloadingSlots is set after outcome `.downloading` with 500ms retry. Two slightly different downloading state machines for same destination — minor duplication.

- `panePreviews: [PaneSlot: PanePreview]` and `loupeVideoState` are parallel dictionaries for same loupe pane (one holds CGImage, one holds AVPlayer). PanePresentation now handles `.video` vs `.full` priority, but ViewModel’s `refreshPanePreviews` clears image state while Task clears video state separately — two paths for “loupe content”.

Severity: low. Acceptable today because compare stays image-only, but loupe has two content stores.

### 4.4 AppKit bridge sprawl

- `MediaGridBridgeView` (NSCollectionView) + `LoupeVideoPlayerView` (AVPlayerView) are two NSViewRepresentable bridges. Each is 30-40 lines, passive. Not sprawl yet. Risk if loupe adds custom AVPlayerLayer wrapper: would be third.

Severity: none observed. Noted for plan.

### 4.5 Unsafe concurrency escape

- `VideoPreviewLoader.swift:135 nonisolated(unsafe) let player` + `@unchecked Sendable` is explicit unsafe escape, guarded by MainActor.run. Also `MediaImportExecutor.swift:1341 nonisolated(unsafe) var cancelled` in CancelFlag (with NSLock) — correctly guarded but same spelling would appear in audit.

- No `Task.detached` escapes found. All long-lived streams capture weak.

Severity: low-medium, isolated to video.

### 4.6 SwiftUI body work

- `LoupeView.body` and `CompareView` are passive: render provided state, call ViewModel intents, no catalog/DB/scan. `MediaAssetTileView` loads via TileContentStore off MainActor correctly. No body work observed.

### 4.7 Other lint smells (non-gravity)

- `script/lint.sh` 229 warnings, 0 serious. Top: `file_length` on `CatalogWindowViewModel.swift:784 (>600)`, `function_body_length` on ViewModel init (62) and MediaOperationCoordinatorTests, `identifier_name` on single-letter vars `n`, `a`, `b` in tests, `line_length` on MaterializationCoordinatorProviderBreakerTests.

Per AGENTS.md: file_length/type_body_length are warnings and cohesive type should not be split to satisfy them. ViewModel is already extension-split (ViewMode, Selection, SourceMonitoring); further split would hurt cohesion.

Severity: accepted.

## 5. Research conclusions: bandaid vs blank-slate

### The bandaid (what landed in #173)

- Keep `actor VideoPreviewLoader` off MainActor; store `AVPlayer` as `nonisolated(unsafe) @unchecked Sendable`; hop to MainActor for every player touch; duplicate state in loader + ViewModel; mark tests `@MainActor` to access `id`.

Why it passed: suspending `await materialize` inside actor does not block MainActor; actor serialises focus-change vs play. Tests green after @MainActor annotation. No crash.

Why it is a smell: defeats complete checking; future maintainer adds `player.seek` off MainActor and compiler does not error (it is nonisolated). Stores MainActor object in non-MainActor isolation domain — exactly the “unsafe escape” smell.

### Blank-slate alternatives evaluated

**A. `@preconcurrency import AVFoundation`**

Downgrades imported MainActor to non-isolated with warnings. Loader stays `actor`.

Pros: one-line, restores old SDK behavior.
Cons: hides all AVFoundation isolation, not just AVPlayer; future SDKs may add more MainActor annotations that silently lose safety. Rejected — docs/adr ownership says prefer explicit ownership.

**B. Isolated box: actor holds `@MainActor Box<AVPlayer>`**

Loader stays `actor`; player lives in `@MainActor final class PlayerBox { let player: AVPlayer }`. Actor holds `Box` as `nonisolated` but can only touch via `await box.withPlayer { }`.

Pros: preserves actor off MainActor for materialization; no unsafe.
Cons: still hops for every touch; box is extra indirection; duplication remains.

**C. Make VideoPreviewLoader `@MainActor` (chosen blank-slate)**

Turn `actor VideoPreviewLoader` into `@MainActor final class VideoPreviewLoader` (or `actor` annotated `@MainActor`). LoupeVideoState becomes `@MainActor struct` with normal `let player: AVPlayer` (no unchecked, no unsafe). ViewModel already `@MainActor`, so whole loupe video flow lives on one serial executor; `await materialize` still suspends without blocking main thread (Swift async on MainActor frees thread at suspension). No duplicate state: make loader stateless factory (`func makePlayer(...) -> AVPlayer?`) and let ViewModel own `loupeVideoState` as single source, or let loader own `currentState` and ViewModel expose it via `var loupeVideoState: LoupeVideoState? { videoLoader.currentState }` with @Observable publication.

Also fix default-isolation tax: annotate pure domain value types as `nonisolated` (or `nonisolated` on extensions) so they stay off MainActor: `nonisolated struct MediaAssetID`, `nonisolated struct MediaRelativePath`, `nonisolated struct PanePreview`, etc. Alternatively, keep types plain and add `nonisolated` on conformances where Swift 6.2 requires. This eliminates future “id is MainActor-isolated” traps without scattering `@MainActor` on tests.

Why C wins: one owner per question (player lifecycle owned by MainActor loader or directly by ViewModel), no unsafe, matches SDK’s isolation intent (player is UI object like AVPlayerView), aligns with existing ViewModel being @MainActor bridge — the increment already makes loupe video UI-only (loupe only, not compare, not grid). Cost: loader moves onto MainActor, but heavy work (materialize 120s with 1s polls, FileHandle read) already hops off via coordinator; player creation is cheap (MainActor run was already needed). Complexity down, safety up.

**D. Split LoupeContent into single enum (image | video) instead of two optionals**

Current: `panePreviews[.loupe]` holds image, `loupeVideoState` holds video, display picks video first. Blank-slate would `enum LoupeContent { case empty, image(PanePreview), video(LoupeVideoState), downloading }` with one property on ViewModel.

Pros: removes parallel nil checks.
Cons: mixes CGImage and AVPlayer into one enum that is either @MainActor (because AVPlayer) or unsafe; premature generalization until compare gains video.

Rejected for 0070: keep two stores until compare video decision; document that loupe has two content slots by design (poster vs player).

## 6. Plan direction

Plan 0070 should:

1. Change `VideoPreviewLoader` from `actor` to `@MainActor final class` (or `@MainActor actor`), remove `nonisolated(unsafe)`/`@unchecked Sendable` on LoupeVideoState, make LoupeVideoState `@MainActor` with normal AVPlayer, remove duplicate `currentState` vs `loupeVideoState` by making ViewModel the single owner (stateless factory) or loader the single owner with projected read-only.
2. Annotate pure Sendable models as `nonisolated` to survive `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` without test workarounds (or at minimum add `nonisolated` to MediaAssetID, MediaRelativePath, PanePreview, LoupeVideoState.id accessors).
3. Keep lint-smell acceptances explicit; do not split ViewModel file.
4. Verify with `script/verify.sh` green, `script/lint.sh` 0 serious, `script/build.sh` BUILD SUCCEEDED, and that no `nonisolated(unsafe)` AVPlayer remains.

## Sources

- First-party: `swift-evolution/visions/approachable-concurrency.md`, proposal 0423 `dynamic-actor-isolation.md`, proposal 0337, Apple docs `AVPlayer`/`AVPlayerItem`/`AVPlayerView` via `script/apple-docs.sh` 2026-08-07, Xcode 27.0 SDK headers (AVPlayer @MainActor), WWDC25 Approachable Concurrency session.
- Second-party: Donny Wals “Setting default actor isolation in Xcode 26” (2025), Swift Forums threads `default-actor-isolation-mainactor-conflicts-with-sendable` (eskimo 2026-06-29), `is-concurrent-now-the-standard-tool` (McCall 2025-11-01), `insight-needed-for-equatable-with-default-mainactor-isolation` (Shier 2025-09-06), SwiftLint file_length rule discussion in AGENTS.md, Otos ADRs 0004/0006/0008.
