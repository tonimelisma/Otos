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

    /// DES-022: the player is sized to the picture so AVKit has no letterbox to
    /// paint black. A phone portrait clip is stored landscape with a quarter-turn
    /// transform; its displayed size is portrait.
    @Test func displaySizeAppliesThePreferredTransform() {
        let stored = CGSize(width: 1920, height: 1080)
        #expect(LoupeVideoState.displaySize(naturalSize: stored, preferredTransform: .identity) == stored)
        let portrait = LoupeVideoState.displaySize(
            naturalSize: stored,
            preferredTransform: CGAffineTransform(rotationAngle: .pi / 2)
        )
        #expect(portrait.map { $0.width.rounded() } == 1080)
        #expect(portrait.map { $0.height.rounded() } == 1920)
        #expect(LoupeVideoState.displaySize(naturalSize: .zero, preferredTransform: .identity) == nil)
    }

    /// The video pane reports its measured size, so the curation group rides the
    /// video's own corner (DES-066); an unmeasured video reports none.
    @Test func videoPaneReportsItsDisplaySize() {
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Library/Root"),
            relativePath: MediaRelativePath(rawValue: "d.mov")
        )
        let measured = LoupeVideoState(
            id: id, player: AVPlayer(), isPlaying: false, displaySize: CGSize(width: 1080, height: 1920)
        )
        #expect(PanePresentation.Display.video(measured).mediaPixelSize == CGSize(width: 1080, height: 1920))
        let unmeasured = LoupeVideoState(id: id, player: AVPlayer(), isPlaying: false)
        #expect(PanePresentation.Display.video(unmeasured).mediaPixelSize == nil)
    }
}
