import AVKit
@testable import OtosKit
import Testing

@MainActor
struct LoupeVideoPlayerTests {
    // Validates: APP-020
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

    // Validates: APP-020
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
}
