import AppKit
import AVKit
import SwiftUI

/// Loupe video player view guide
///
/// Passive `NSViewRepresentable` wrapper around `AVPlayerView` (AppKit). The
/// SwiftUI loupe pane owns *when* video appears; this view owns *how* it
/// looks: `controlsStyle=.inline` bar along the bottom edge, QuickTime parity
/// without custom `AVPlayerLayer` reimplementation. No catalog or materialization knowledge.
struct LoupeVideoPlayerView: NSViewRepresentable {
    let state: LoupeVideoState

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
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
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
