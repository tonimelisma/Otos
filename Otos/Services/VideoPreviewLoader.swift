import AVFoundation
import Foundation
import OSLog

/// Loupe video loader guide
///
/// The loupe analog of `PreviewImageLoader`: a `@MainActor` stateless factory
/// that gates on `FileMaterialization.status` immediately before any byte-backed
/// `AVPlayerItem` init, deliberately materializes dataless originals through the
/// shared `MaterializationCoordinator` at interactive priority when the user has
/// opened the asset in loupe, and returns a `LoupeVideoState` holding a paused
/// player.
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

    /// Gates on live `SF_DATALESS`, materializes at interactive priority if
    /// dataless, re-checks before `AVPlayerItem` init, then creates the player —
    /// paused. Starting playback is the caller's intent, not this factory's.
    /// Returns `nil` for `providerUnavailable`/`timedOut`/`unknown` and for
    /// non-video kinds — caller keeps the poster thumbnail. Suspends at the
    /// materialization await without blocking the main thread.
    func preparePlayer(id: MediaAssetID, detail: MediaTileDetail?) async -> LoupeVideoState? {
        guard detail?.bestKind == .video else {
            return nil
        }
        let url = id.fileURL

        switch status(url) {
        case .dataless:
            OtosLog.mediaIO.notice(
                "op=video.decode phase=materialize id=\(id.relativePath.rawValue, privacy: .public)"
            )
            let result = await materializationRequester.materialize(
                MaterializationCoordinator.Request(
                    id: id,
                    sourceSize: detail?.enrichedSourceSize,
                    isVideo: true,
                    priority: .interactive
                )
            )
            guard result.isMaterialized else {
                OtosLog.mediaIO.notice(
                    """
                    op=video.decode phase=downloading id=\(id.relativePath.rawValue, privacy: .public) \
                    outcome=\(result.outcome.diagnosticDescription, privacy: .public)
                    """
                )
                return nil
            }
        case .unknown:
            OtosLog.mediaIO.notice(
                "op=video.decode phase=unavailable id=\(id.relativePath.rawValue, privacy: .public)"
            )
            return nil
        case .materialized:
            break
        }

        guard status(url) == .materialized else {
            return nil
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
        return state
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
