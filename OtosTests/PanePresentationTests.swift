import CoreGraphics
import Foundation
@testable import OtosKit
import Synchronization
import Testing

struct PanePresentationTests {
    @Test func matchingPreviewIDYieldsFull() {
        let id = makePaneID("a.jpg")
        let image = makePaneCGImage()
        let preview = PanePreview(id: id, image: image)
        #expect(PanePresentation.display(paneID: id, preview: preview) == .full(image))
    }

    @Test func mismatchedPreviewFallsBackToThumbnail() {
        let pane = makePaneID("pane.jpg")
        let other = makePaneID("other.jpg")
        let preview = PanePreview(id: other, image: makePaneCGImage())
        #expect(PanePresentation.display(paneID: pane, preview: preview) == .thumbnail(pane))
    }

    /// DES-066: the group rides the pane's *image*, not the pane. A pane wider
    /// than its photo paints black beside it, and a group anchored to the pane
    /// corner sits in that letterbox instead of on the picture. The pane can only
    /// place it where it knows the media's size, so the size is reported here and
    /// absent where the pane genuinely does not have it.
    @Test func onlyAFullImagePaneKnowsWhereItsMediaIs() {
        let landscape = makePaneCGImage(width: 1600, height: 400)
        #expect(PanePresentation.Display.full(landscape).mediaPixelSize
            == CGSize(width: 1600, height: 400))

        // A poster or a video carries no size here; nil is the honest answer and
        // `contentRect` turns it into the pane's own bounds rather than a guess.
        #expect(PanePresentation.Display.thumbnail(makePaneID("p.jpg")).mediaPixelSize == nil)
        #expect(PanePresentation.Display.empty.mediaPixelSize == nil)

        // And the size actually moves the group: in a square pane this landscape
        // image letterboxes top and bottom, so the group drops with the picture.
        let pane = CGRect(x: 0, y: 0, width: 800, height: 800)
        let face = MediaAssetTilePresentation.contentRect(
            imagePixelSize: PanePresentation.Display.full(landscape).mediaPixelSize,
            bounds: pane
        )
        #expect(face.minY > pane.minY)
        #expect(face.height < pane.height)

        // Nil falls back to the whole pane, which is the previous behaviour.
        let unknown = MediaAssetTilePresentation.contentRect(imagePixelSize: nil, bounds: pane)
        #expect(unknown == pane)
    }

    /// One thing at the pane's center (DES-086): the wait while bytes or a player are
    /// coming, else why a video cannot play, else nothing — and only for the pane's asset.
    @Test func paneOverlayShowsTheWaitOrWhyNeverBoth() {
        let pane = makePaneID("v.mp4")
        let other = makePaneID("w.mp4")
        #expect(PanePresentation.overlay(paneID: pane, isDownloading: false, video: nil) == .none)
        #expect(PanePresentation.overlay(paneID: pane, isDownloading: true, video: nil) == .waiting)
        #expect(PanePresentation.overlay(paneID: pane, isDownloading: false, video: (pane, .preparing)) == .waiting)
        #expect(PanePresentation.overlay(paneID: pane, isDownloading: false, video: (pane, .ready)) == .none)
        #expect(PanePresentation.overlay(
            paneID: pane, isDownloading: false, video: (pane, .unavailable(.serverUnreachable))
        ) == .unavailable(.serverUnreachable))
        #expect(PanePresentation.overlay(
            paneID: pane, isDownloading: true, video: (pane, .unavailable(.serverUnreachable))
        ) == .waiting)
        #expect(PanePresentation.overlay(
            paneID: pane, isDownloading: false, video: (other, .unavailable(.serverUnreachable))
        ) == .none)
    }
}

private func makePaneID(_ path: String) -> MediaAssetID {
    MediaAssetID(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path)
    )
}

private func makePaneCGImage(width: Int = 8, height: Int = 8) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}
