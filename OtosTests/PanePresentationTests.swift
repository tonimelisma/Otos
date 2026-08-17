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

    @Test func nilPaneIsEmpty() {
        let preview = PanePreview(id: makePaneID("x.jpg"), image: makePaneCGImage())
        #expect(PanePresentation.display(paneID: nil, preview: preview) == .empty)
    }

    @Test func nilPreviewFallsBackToThumbnail() {
        let pane = makePaneID("pane.jpg")
        #expect(PanePresentation.display(paneID: pane, preview: nil) == .thumbnail(pane))
    }
}

private func makePaneID(_ path: String) -> MediaAssetID {
    MediaAssetID(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path)
    )
}

private func makePaneCGImage() -> CGImage {
    let context = CGContext(
        data: nil,
        width: 8,
        height: 8,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}
