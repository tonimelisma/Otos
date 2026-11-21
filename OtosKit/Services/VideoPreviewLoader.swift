import AVFoundation
import Foundation
import OSLog

/// Loupe video loader guide
///
/// The loupe analog of `PreviewImageLoader`: a `@MainActor` stateless factory
/// that asks the shared `MaterializationCoordinator` to make the original local
/// (`ensureLocal`, interactive priority, because the user has opened the asset in
/// loupe), re-checks `FileMaterialization.status` immediately before any
/// byte-backed `AVPlayerItem` init, and returns a `LoupeVideoState` holding a
/// paused player.
///
/// Why `@MainActor` and stateless: `AVPlayer`/`AVPlayerItem` are `@MainActor`
/// in the macOS 27 SDK — a video player is a UI object like `AVPlayerView`.
/// The owner of loupe `AVPlayer` lifecycle is the `@MainActor` ViewModel's
/// published `loupeVideoState` (single owner, no duplication). This factory
/// holds no `currentState`; it only checks materialization, creates the player
/// on the main actor, and exposes a synchronous `cleanup` helper. Stale results
/// are rejected by the ViewModel's expected-asset identity check
/// (`LoupeVideoState.id == focusedAssetID`), same pattern `PanePreview` uses.
@MainActor
final class VideoPreviewLoader {
    private let materializationRequester: any MaterializationRequesting
    private let status: @Sendable (URL) -> FileMaterializationStatus

    init(
        status: @escaping @Sendable (URL) -> FileMaterializationStatus = FileMaterialization.status(of:),
        materializationRequester: any MaterializationRequesting
    ) {
        self.status = status
        self.materializationRequester = materializationRequester
    }

    /// Makes the original local at interactive priority, re-checks before
    /// `AVPlayerItem` init, then creates the player — paused. Starting playback
    /// is the caller's intent, not this factory's.
    /// Answers why there is no player when the bytes cannot come, so the pane can say
    /// so (DES-086), and `.notVideo` for any other kind. Suspends at the
    /// materialization await without blocking the main thread.
    func preparePlayer(id: MediaAssetID, detail: MediaTileDetail?) async -> LoupeVideoPreparation {
        guard detail?.bestKind == .video else {
            return .notVideo
        }
        let url = id.fileURL

        let readiness = await materializationRequester.ensureLocal(
            MaterializationCoordinator.Request(
                id: id,
                sourceSize: detail?.byteSize,
                isVideo: true,
                priority: .interactive
            )
        )
        guard readiness.isLocal else {
            OtosLog.mediaIO.notice(
                """
                op=video.decode phase=unavailable id=\(id.relativePath.rawValue, privacy: .public) \
                readiness=\(String(describing: readiness), privacy: .public)
                """
            )
            return .unavailable(LoupeVideoUnavailable(readiness))
        }

        // Re-check immediately before the byte-backed player item (ADR 0008): a file the
        // provider evicted again since is one whose download did not hold.
        guard status(url) == .materialized else {
            OtosLog.mediaIO.noticeOperation("video.decode", phase: "unavailable", fields: [
                "id": id.relativePath.rawValue, "readiness": "evictedBeforeRead",
            ])
            return .unavailable(.downloadFailed)
        }

        let asset = AVURLAsset(url: url)
        let displaySize = await Self.displaySize(of: asset)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause

        var state = LoupeVideoState(id: id, player: player, isPlaying: false, displaySize: displaySize)
        state.applyTrim(detail?.editRecipe ?? .neutral)
        OtosLog.mediaIO.notice(
            """
            op=video.decode phase=ok id=\(id.relativePath.rawValue, privacy: .public) \
            displaySize=\(displaySize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown", privacy: .public)
            """
        )
        return .ready(state)
    }

    /// The first video track's size as displayed — `naturalSize` through its
    /// `preferredTransform`, so a rotated portrait clip reads portrait. Nil when the
    /// asset has no readable video track; the pane then gives the player its full
    /// frame rather than inventing an aspect ratio.
    private static func displaySize(of asset: AVURLAsset) async -> CGSize? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else {
            return nil
        }
        return LoupeVideoState.displaySize(naturalSize: naturalSize, preferredTransform: transform)
    }

    /// Synchronous MainActor cleanup helper — caller owns the player.
    func cleanup(_ state: LoupeVideoState) {
        state.player.pause()
        state.player.replaceCurrentItem(with: nil)
    }
}

/// What preparing a video for the loupe came to: a paused player, or why there is none.
@MainActor
enum LoupeVideoPreparation: Equatable {
    case ready(LoupeVideoState)
    case unavailable(LoupeVideoUnavailable)
    /// The asset is not a video; nothing was asked for.
    case notVideo
}

/// Why the loupe has no player for a video, or for a Live Photo's motion: the reason the
/// pane names under `Can’t play this video` (DES-086). Each case is a state of the source
/// or of this Mac, read from what the request for the original's bytes answered.
nonisolated enum LoupeVideoUnavailable: Equatable, Sendable {
    /// The Immich server did not answer the download.
    case serverUnreachable
    /// The camera or card the video is on is not connected.
    case deviceUnavailable
    /// The library the video is in is not reachable.
    case libraryUnavailable
    /// Downloading it would take the volume below the free-space floor (ADR 0027).
    case insufficientSpace
    /// This session never downloads originals: a read-only tour (`ReadOnlyOriginals`).
    case downloadsOff
    /// The provider was asked and the bytes did not arrive.
    case downloadFailed
    /// The catalog could not read the video's row, so nothing was asked for.
    case detailUnreadable

    init(_ readiness: EnsureLocalOutcome) {
        switch readiness {
        case .local:
            self = .downloadFailed
        case .unreachable:
            self = .libraryUnavailable
        case .userWorkOnly:
            self = .downloadFailed
        case let .notMaterialized(outcome):
            switch outcome {
            case .serverUnreachable: self = .serverUnreachable
            case .deviceUnavailable: self = .deviceUnavailable
            case .insufficientLocalSpace: self = .insufficientSpace
            case .refusedReadOnly: self = .downloadsOff
            case .alreadyMaterialized, .materialized, .requestFailed, .timedOut, .providerUnavailable,
                 .cancelled, .statusUnavailable:
                self = .downloadFailed
            }
        }
    }
}

/// The loupe's one answer to "what about the video on screen": being prepared, playable,
/// or not playable and why. Its id is the asset the pane shows — the video, or the Live
/// Photo whose motion it plays — and the pane draws it only for that asset.
@MainActor
enum LoupeVideo: Equatable {
    case preparing(MediaAssetID)
    case ready(LoupeVideoState)
    case unavailable(MediaAssetID, LoupeVideoUnavailable)

    var id: MediaAssetID {
        switch self {
        case let .preparing(id), let .unavailable(id, _): id
        case let .ready(state): state.id
        }
    }

    /// The same answer without the player, for the pane's pure presentation decisions.
    var phase: LoupeVideoPhase {
        switch self {
        case .preparing: .preparing
        case .ready: .ready
        case let .unavailable(_, reason): .unavailable(reason)
        }
    }
}

nonisolated enum LoupeVideoPhase: Equatable, Sendable {
    case preparing
    case ready
    case unavailable(LoupeVideoUnavailable)
}

/// Loupe video state — identity-guarded like `PanePreview`.
///
/// Views render this only when `id == focusedAssetID`; otherwise they fall
/// back to the thumbnail poster. `@MainActor` because it holds `AVPlayer`
/// (MainActor-isolated in AVFoundation 27); `id` is `nonisolated` so
/// identity checks (PanePresentation, ViewModel stale guards) do not need
/// a MainActor hop. Equality on `player` checks pointer identity.
@MainActor
struct LoupeVideoState: Equatable {
    nonisolated let id: MediaAssetID
    let player: AVPlayer
    var isPlaying: Bool
    /// The video's displayed size, so the pane sizes the player to the picture and
    /// leaves no letterbox for AVKit to paint black (DES-022). Nil when unknown.
    nonisolated let displaySize: CGSize?
    /// The video's saved edit, whose trim the player plays (ADR 0036).
    private(set) var recipe = EditRecipe.neutral

    init(id: MediaAssetID, player: AVPlayer, isPlaying: Bool, displaySize: CGSize? = nil) {
        self.id = id
        self.player = player
        self.isPlaying = isPlaying
        self.displaySize = displaySize
    }

    nonisolated static func displaySize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize? {
        let size = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform).size
        guard size.width > 0, size.height > 0 else {
            return nil
        }
        return size
    }

    /// Plays only the recipe's trimmed range: `AVPlayerItem`'s reverse and forward playback
    /// end times are where `AVPlayerView`'s trim UI reads and writes it, so the player and the
    /// trim UI show the same range. An untrimmed recipe clears them.
    mutating func applyTrim(_ recipe: EditRecipe) {
        self.recipe = recipe
        guard let item = player.currentItem else { return }
        item.reversePlaybackEndTime = recipe.trimStart.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .invalid
        item.forwardPlaybackEndTime = recipe.trimEnd.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .invalid
        if let start = recipe.trimStart {
            let time = CMTime(seconds: start, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// The trimmed range the player's item holds now, as the trim UI left it: nil at an end
    /// the trim did not move.
    var currentTrim: (start: Double?, end: Double?) {
        guard let item = player.currentItem else { return (nil, nil) }
        let duration = item.duration
        let start = item.reversePlaybackEndTime
        let end = item.forwardPlaybackEndTime
        let startSeconds = start.isValid && start.seconds > 0 ? start.seconds : nil
        let endSeconds = end.isValid && (!duration.isNumeric || end < duration) ? end.seconds : nil
        return (startSeconds, endSeconds)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.player === rhs.player && lhs.isPlaying == rhs.isPlaying && lhs.recipe == rhs.recipe
    }
}
