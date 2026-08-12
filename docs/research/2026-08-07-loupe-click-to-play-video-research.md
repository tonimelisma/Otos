# 2026-08-07 — Loupe click-to-play video research

Sources: Apple Developer Documentation via `script/apple-docs.sh` (sosumi.ai) + second-party blogs, GitHub, and product write-ups. No originals were read or modified. Evaluated against Otos constraints: single `Window("Otos", id:"main")`, filesystem as source of truth, `SF_DATALESS` gate, `MaterializationCoordinator` interactive priority, loupe not compare (`PanePresentation` identity rule).

## 1. First-party Apple APIs

### VideoPlayer (SwiftUI, AVKit)
* **Declaration:** `struct VideoPlayer<VideoOverlay>: View` — `Available on: iOS 14.0+, macOS 11.0+` [source: /documentation/avkit/videoplayer — 2026-08-07T05:56:08Z]
* **What it is:** `A view that displays content from a player and a native user interface to control playback.` Inits `init(player:)` and `init(player:videoOverlay:)`.
* **Apple guidance in docs:** Create the `AVPlayer` in a `.task` modifier (`@State private var player: AVPlayer?`) to avoid performance issues and side effects from creating it during `body`. Example shows deferred creation then `VideoPlayer(player: player)` [same source].
* **Otos fit:** SwiftUI-native, no AppKit bridge. But second-party assessment (see §2) is that `VideoPlayer` is thin and limited: `inline only, no full-screen button, no PiP, limited customization` [@danielcrompton5 — PiP blog, also vdocipher table: `AVPlayerViewController`/`VideoPlayer` = minimal effort, less control].
* **Controls:** `VideoPlayer` exposes the system inline controls implicitly; no `controlsStyle` API. To get `inline` / `floating` / `minimal` / `none` you need the AppKit type.

### AVPlayerView (AppKit, AVKit)
* **Declaration:** `class AVPlayerView: NSView` — `Available on: macOS 10.9+` [source: /documentation/avkit/avplayerview — 2026-08-07T05:56:12Z]
* **What it is:** `A view that displays content from a player and presents a native user interface to control playback.` Inherits `NSView`, supports QuickTime-style trimming UI.
* **Controls styles:** `enum AVPlayerViewControlsStyle: none | inline | floating | minimal | default` [source: /documentation/avkit/avplayerviewcontrolsstyle — 2026-08-07T05:56:24Z]. Key API: `controlsStyle`, `showsFrameSteppingButtons`, `showsSharingServiceButton`, `showsFullScreenToggleButton`, `contentOverlayView`, `actionPopUpButtonMenu` [same AVPlayerView source — Customizing the user interface].
* **Keyboard shortcuts built-in:** Space play/pause, left/right frame step, J/K/L shuttle [same source — Overview].
* **Video gravity/bounds:** `videoGravity`, `videoBounds`, `isReadyForDisplay` [same source].
* **Why loupe wants it:** Click-to-play wants a poster-first state with controls hidden until play. `controlsStyle=.inline` after play gives the bar along bottom edge matching loupe's black `0.92` backdrop; `minimal` would only give play/pause, `floating` is HUD over video, `none` is custom-controls only. `showsSharingServiceButton=false` keeps Otos chrome minimal; `showsFullScreenToggleButton=true` is useful in the large main-window loupe pane.
* **Integration:** `AVPlayerView` is `NSView`, so SwiftUI wrapper is `NSViewRepresentable` (APIs `makeNSView`/`updateNSView`), parallel to `MediaGridBridgeView`'s `NSCollectionView` bridge — the one AppKit boundary already exists in Otos, so no new architectural pattern. Blog reference: `sergioestevao.com/2020/02/22/video-in-swiftui-macos` shows `NSViewRepresentable` wrapping `AVPlayerView` for macOS, using a `Coordinator` [web_search 2020-02-22 result].

### AVPlayer (AVFoundation)
* **Declaration:** `@MainActor class AVPlayer` — `Available on: macOS 10.7+` [source: /documentation/avfoundation/avplayer — 2026-08-07T05:56:12Z]
* **Role:** `A player is a controller object that manages the playback and timing of a media asset.` Reusable via `replaceCurrentItem(with:)`; single item at a time; `AVQueuePlayer` for queues [same source — Overview]. `AVAsset` is static (duration etc.), `AVPlayerItem` is dynamic timing/presentation [same source].
* **Observation:** KVO for `currentItem`/`rate`, plus `addPeriodicTimeObserver` / `addBoundaryTimeObserver` for time; `removeTimeObserver` to cancel [same source — Observing playback time]. `timeControlStatus`/`reasonForWaitingToPlay` / `automaticallyWaitsToMinimizeStalling` for buffering [same source].
* **Otos implication:** One `AVPlayer` per loupe pane, not per grid cell (see §2 performance). Loupe's `PanePreview` identity `id == focusedAssetID` already guards stale decodes; same guard works for `AVPlayerItem(url: fileURL)` swaps.

### AVPlayerItem + AVPlayerLayer
* **AVPlayerItem:** `@MainActor class AVPlayerItem` — supports `status`/`error`, `loadedTimeRanges`/`seekableTimeRanges`, `isPlaybackLikelyToKeepUp`, `accessLog`/`errorLog` [source: /documentation/avfoundation/avplayeritem — 2026-08-07T05:56:24Z]. `duration`/`presentationSize` useful for badge vs player sizing.
* **AVPlayerLayer:** `class AVPlayerLayer: CALayer` with `videoGravity`/`isReadyForDisplay` [source: /documentation/avfoundation/avplayerlayer — 2026-08-07T05:56:41Z]. Used only if we build custom controls (`VideoPlayer`/`AVPlayerView` both host `AVPlayerLayer` internally). Not needed for loupe click-to-play unless `controlsStyle=.none` is chosen.

## 2. Second-party blogs, GitHub, and product experiences

### When to prefer which wrapper (consistent across 5+ sources)
* **VideoPlayer is iOS answer, AVPlayerViewController/AVPlayerView is macOS answer:** `vdocipher.com/blog/avplayer` table — `AVPlayerViewController` (iOS) / `AVPlayerView` (macOS) = `Best for Standard Apple-style video playback UI` with `Native controls, fullscreen, subtitles, AirPlay, PiP support`; `AVPlayerLayer` = custom controls. Limits: `Less control over deep UI customization` [web_search vdocipher 2025 result, also ChrisMash/AVPlayer-SwiftUI README: `VideoPlayer is SwiftUI's answer to AVPlayerViewController, if you're happy with default controls drop it in`].
* **SwiftUI VideoPlayer is limited on macOS:** `medium @danielcrompton5 2026` — `VideoPlayer view that takes AVPlayer and represents a very simple and limited inline video player. It doesn't have a full-screen button so you're limited to inline only, no PiP` [web_search]. Same blog shows replacing `VideoPlayer` with `UIViewControllerRepresentable` wrapping `AVPlayerViewController` to get `showsPlaybackControls`, `allowsPictureInPicturePlayback`, `canStartPictureInPictureAutomaticallyFromInline`. For macOS the equivalent is `AVPlayerView` with `allowsPictureInPicturePlayback`/`allowsMagnification` [Apple docs list].
* **Controls customization gap:** `frederikhandberg0709/AVPlayerView-Conditional-Controls` notes `controlsStyle=.none` hides controls but leaves two layers (`EventPassthrough`/`MovableView`) — confirms `AVPlayerView` is the knob, not `VideoPlayer`, and conditional hiding works via scale/zoom [web_search — GitHub snippet].
* **NSViewRepresentable pattern for macOS:** `sergioestevao.com 2020-02-22` — `NSViewRepresentable` + `Coordinator` wrapping `AVPlayerView`, setting `player` and `controlsStyle`, bridging `AVPlayerViewDelegate` [web_search]. Mirror of Otos `MediaGridBridgeView`.

### Performance: thumbnail-first, not player-per-cell
* `medium @kost9klinov 2026-06: Mastering Video Playback in iOS: Best Practices for UITableView` — allocating `AVPlayer` per cell `quickly max out memory, spike CPU, cause scrolling to stutter.` Recommendation `Thumbnail First` — initialize `AVPlayerItem`/`AVPlayer` only on user intent, not on cell load [web_search — June 2026 Medium snippet, echoed by `greypatterson.me 2021 Playing Videos in SwiftUI` overlay example and `kost9klinov` June 2026 second hit].
* **Otos consequence:** Grid filmstrip stays `PaneThumbnailView` (256 px JPEG via `TileContentStore`); loupe detail creates `AVPlayer` only on click. Do not change `CatalogStore` or `MediaOperationCoordinator`; do not create `AVPlayer` in grid `MediaGridBridgeView`.

### Click-to-play UX and overlay
* `medium @rushangprajapati08 How I Built a Custom Video Player in SwiftUI Using AVPlayer` — builds custom controls via `AVPlayer` + `AVPlayerLayer` in `UIViewRepresentable`, keeping control over layer [web_search]. For Otos, native `AVPlayerView.controlsStyle=.inline` is sufficient; custom overlay only needed if design wants a centered play glyph over the thumbnail before first play (poster-first).
* `globulus/Enhanced SwiftUI Video Player` gist — `VideoPlayer(player: viewModel.player, videoOverlay: videoOverlay)` pattern shows SwiftUI `videoOverlay` for play button before `isPlaying` [web_search — gist snippet]. For `AVPlayerView`, the equivalent is `contentOverlayView` or a SwiftUI `ZStack` over the `NSViewRepresentable`.
* **Otos click-to-play shape that satisfies `TileContentStore` never-blank invariant:** Keep the thumbnail visible until `AVPlayerView.isReadyForDisplay` (or `AVPlayerItem.status == .readyToPlay`) becomes true, then cross-fade. Never show another asset's frame; stale `AVPlayerItem` swaps cancel the previous player's periodic observer.

### Codec and HDR coverage
* Apple docs `AVPlayerItem` exposes `presentationSize`, `preferredMaximumResolution`, `appliesPerFrameHDRDisplayMetadata` [Apple source tail]; `AVPlayerView` has `preferredDisplayDynamicRange` for HDR [Apple AVPlayerView HDR section]. No extra framework needed for H.264/HEVC/ProRes — `AVFoundation` already handles Otos image/video product scope (image/video, never audio-only per `AGENTS.md`).

## 3. Conclusions for Otos loupe click-to-play (not compare)

* **Use `AVPlayerView` (AppKit) wrapped in `NSViewRepresentable`, not `VideoPlayer`.** `VideoPlayer` lacks `controlsStyle`, lacks macOS full-screen toggle, and is documented as `limited` by second-party experience; `AVPlayerView` gives the exact `inline` bar Otos wants in the large main-window loupe pane while keeping the existing one-AppKit-boundary pattern (`MediaGridBridgeView`).
* **Poster-first, one player at a time:** Loupe pane starts as `PanePresentation.display == .thumbnail` (existing). A single tap creates `AVPlayer(url: fileURL)` after `FileMaterialization.status == .materialized`; if `.dataless`, route through `MaterializationCoordinator` at interactive priority exactly as `PreviewImageLoader` does for full-size decodes, showing `isDownloading` `ProgressView` already in `LoupeView.previewPane`. No grid-side `AVPlayer` allocation (performance rule from §2).
* **Identity guard:** `focusedAssetID` is the identity. `AVPlayerView` wrapper stores `currentAssetID`; when `focusedAssetID` changes, the previous `AVPlayer` is `pause()`d, `replaceCurrentItem(with: nil)`, periodic observer removed, and `isPlaying` state reset — same stale-discard rule `PanePreview` uses (`image ===` check).
* **Controls:** `controlsStyle=.inline`, `showsSharingServiceButton=false`, `showsFrameSteppingButtons=true`, `showsFullScreenToggleButton=true`, `allowsPictureInPicturePlayback=false` (loupe is the large window, not a floating window), `allowsMagnification=false`.
* **Cleanup:** `AVPlayer` is `@MainActor`; removal of `AVPlayerView` from the hierarchy must `removeTimeObserver` and `pause()` on the main actor, mirroring `CatalogWindowViewModel` task lifetime rules.

## Sources

* First-party: `https://developer.apple.com/documentation/avkit/videoplayer`, `/documentation/avkit/avplayerview`, `/documentation/avkit/avplayerviewcontrolsstyle`, `/documentation/avfoundation/avplayer`, `/documentation/avfoundation/avplayeritem`, `/documentation/avfoundation/avplayerlayer`, `/documentation/avkit/avplayerviewdelegate` (all via `script/apple-docs.sh` 2026-08-07, sosumi.ai).
* Second-party: `vdocipher.com/blog/avplayer` (AVPlayer table), `sergioestevao.com/2020/02/22/video-in-swiftui-macos` (NSViewRepresentable AVPlayerView), `medium @danielcrompton5 — SwiftUI video & audio player with PiP & Now Playing support` (VideoPlayer limitations), `medium @kost9klinov 2026-06 Mastering Video Playback in UITableView` (thumbnail-first performance), `medium @rushangprajapati08 How I Built a Custom Video Player in SwiftUI Using AVPlayer` (AVPlayerLayer wrapper pattern), `frederikhandberg0709/AVPlayerView-Conditional-Controls` (controlsStyle .none residual layers), `globulus/Enhanced SwiftUI Video Player gist` (videoOverlay play button), `ChrisMash/AVPlayer-SwiftUI` (WWDC20 VideoPlayer intro).
