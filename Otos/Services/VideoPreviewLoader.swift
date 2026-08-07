import AVFoundation
import Foundation
import OSLog

/// Loupe video loader guide
///
/// The loupe analog of `PreviewImageLoader`: one actor owns the loupe video
/// pane's `AVPlayer` lifecycle. Callers ask to `play(id:)`; this actor gates
/// on `FileMaterialization.status` immediately before any byte-backed `AVPlayerItem`
/// init, deliberately materializes dataless originals through the shared
/// `MaterializationCoordinator` at interactive priority when the user has
/// clicked to play, and returns a `LoupeVideoState` holding the player.
///
/// Why an actor: the player, its time observer, and the materialization await
/// must not interleave with a focus-change clear. The heavy materialization
/// await runs off-actor suspension; only bookkeeping runs on the actor.
///
/// Stale results are rejected by the ViewModel's expected-asset identity check
/// (`LoupeVideoState.id == focusedAssetID`), not by a generation counter —
/// same pattern `PanePreview` uses for decodes.
actor VideoPreviewLoader {
    private let materializationRequester: any MaterializationRequesting
    private let status: @Sendable (URL) -> FileMaterializationStatus
    private var currentState: LoupeVideoState?

    init(
        status: @escaping @Sendable (URL) -> FileMaterializationStatus = FileMaterialization.status(of:),
        materializationRequester: any MaterializationRequesting
    ) {
        self.status = status
        self.materializationRequester = materializationRequester
    }

    /// Gates on live `SF_DATALESS`, materializes at interactive priority if
    /// dataless, re-checks before `AVPlayerItem` init, then creates the player.
    /// Returns `nil` for `providerUnavailable`/`timedOut`/`unknown` and for
    /// non-video kinds — caller keeps the poster thumbnail.
    func play(id: MediaAssetID, detail: MediaTileDetail?) async -> LoupeVideoState? {
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

        // Tear down any previous player before creating the next one.
        if let previous = currentState {
            await pauseAndCleanup(player: previous.player)
        }

        let player: AVPlayer = await MainActor.run {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = true
            player.actionAtItemEnd = .pause
            return player
        }

        let state = LoupeVideoState(id: id, player: player, isPlaying: false)
        currentState = state
        OtosLog.mediaIO.notice(
            "op=video.decode phase=ok id=\(id.relativePath.rawValue, privacy: .public)"
        )
        return state
    }

    func pause() async {
        guard let state = currentState else {
            return
        }
        await pauseAndCleanup(player: state.player)
        currentState = nil
    }

    /// Called on every `focusedAssetID` change. If the current video's id no
    /// longer matches the expected loupe focus, pause and clear it.
    func clearOnFocusChange(expectedID: MediaAssetID?) async {
        guard let state = currentState, state.id != expectedID else {
            return
        }
        await pauseAndCleanup(player: state.player)
        currentState = nil
    }

    /// Single cleanup path: pause, drop item.
    private func pauseAndCleanup(player: AVPlayer) async {
        await MainActor.run {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }
}

/// Loupe video state — identity-guarded like `PanePreview`.
///
/// Views render this only when `id == focusedAssetID`; otherwise they fall
/// back to the thumbnail poster. `AVPlayer` is `@MainActor` isolated in
/// AVFoundation 27, so it is stored `nonisolated(unsafe)` and touched only
/// on `MainActor`. Equality on `player` checks pointer identity.
struct LoupeVideoState: @unchecked Sendable, Equatable {
    let id: MediaAssetID
    nonisolated(unsafe) let player: AVPlayer
    var isPlaying: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.player === rhs.player && lhs.isPlaying == rhs.isPlaying
    }
}
