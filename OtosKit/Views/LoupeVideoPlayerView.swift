import AppKit
import AVKit
import SwiftUI

/// Loupe video player view guide
///
/// Passive `NSViewRepresentable` wrapper around `AVPlayerView` (AppKit). The
/// SwiftUI loupe pane owns *when* video appears; this view owns *how* it
/// looks: `controlsStyle=.inline` bar along the bottom edge, QuickTime parity
/// without custom `AVPlayerLayer` reimplementation. No catalog or materialization knowledge.
///
/// Trimming (ADR 0036): a new `trimCommand` for this video shows `AVPlayerView`'s own trim
/// UI once per generation. Trim reports back through `onTrimmed`, and the view model reads
/// the range the UI left on the player item. Cancel restores the item's previous range and
/// reports nothing.
struct LoupeVideoPlayerView: NSViewRepresentable {
    let state: LoupeVideoState
    /// The story player shows a video with no player chrome (DES-112); the loupe keeps
    /// AVKit's inline bar.
    var showsControls = true
    var trimCommand: VideoTrimCommand?
    var onTrimmed: @MainActor (MediaAssetID) -> Void = { _ in }

    final class Coordinator {
        var appliedTrimGeneration: UInt64 = 0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = showsControls ? .inline : .none
        view.showsFrameSteppingButtons = true
        view.showsSharingServiceButton = false
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = false
        view.allowsMagnification = false
        view.videoGravity = .resizeAspect
        view.player = state.player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== state.player {
            nsView.player = state.player
        }
        guard let command = trimCommand, command.id == state.id,
              command.generation != context.coordinator.appliedTrimGeneration
        else {
            return
        }
        context.coordinator.appliedTrimGeneration = command.generation
        guard nsView.canBeginTrimming else { return }
        let id = state.id
        let onTrimmed = onTrimmed
        nsView.beginTrimming { result in
            if result == .okButton {
                MainActor.assumeIsolated { onTrimmed(id) }
            }
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
