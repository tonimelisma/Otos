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

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause

        let state = LoupeVideoState(id: id, player: player, isPlaying: false)
        OtosLog.mediaIO.notice(
            "op=video.decode phase=ok id=\(id.relativePath.rawValue, privacy: .public)"
        )
        return state
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

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.player === rhs.player && lhs.isPlaying == rhs.isPlaying
    }
}
