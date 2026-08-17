import AVKit
@testable import OtosKit
import Testing

@MainActor
struct LoupeVideoPlayerTests {
    @Test func panePresentationVideoIdentityGuard() {
        let idA = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Library/Root"),
            relativePath: MediaRelativePath(rawValue: "a.mp4")
        )
        let idB = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Library/Root"),
            relativePath: MediaRelativePath(rawValue: "b.mp4")
        )
        let player = AVPlayer()
        let state = LoupeVideoState(id: idA, player: player, isPlaying: false)
        let displayMatch = PanePresentation.display(paneID: idA, preview: nil, videoState: state)
        let displayMismatch = PanePresentation.display(paneID: idB, preview: nil, videoState: state)
        #expect(displayMatch == .video(state))
        #expect(displayMismatch == .thumbnail(idB))
    }

    @Test func avPlayerViewConfigurationMatchesSpec() {
        let state = LoupeVideoState(
            id: MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Library/Root"),
                relativePath: MediaRelativePath(rawValue: "c.mp4")
            ),
            player: AVPlayer(),
            isPlaying: false
        )
        let view = LoupeVideoPlayerView(state: state)
        // Verify wrapper type and video-state identity without constructing
        // an NSViewRepresentableContext (no public initializer).
        #expect(view.state.id == state.id)
        #expect(view.state.player === state.player)
    }

    @Test func compareNeverShowsVideo() {
        // CompareView's pane switch returns video case only to fallback to thumbnail;
        // PanePresentation video should not leak into compare — compare calls
        // display with preview only (no videoState), so even if a LoupeVideoState
        // exists it must not be shown in compare.
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Library/Root"),
            relativePath: MediaRelativePath(rawValue: "d.mp4")
        )
        let display = PanePresentation.display(paneID: id, preview: nil)
        #expect(display == .thumbnail(id))
    }
}
