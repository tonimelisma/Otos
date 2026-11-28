import AppKit
import CoreGraphics
@testable import OtosKit
import Testing

/// The loupe's magnification bounds follow each image: an image small enough to fit above 100
/// percent raises the minimum over the last maximum, which AppKit refuses with an exception
/// unless the maximum makes room first.
@MainActor
struct LoupeZoomScrollViewTests {
    private func image(edge: Int) throws -> DisplayImage {
        DisplayImage.fixture(width: edge)
    }

    // Validates: APP-040
    @Test func aSmallImageAfterALargeOneFitsWithoutCrossingTheBounds() throws {
        let view = LoupeZoomScrollView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1200))
        let large = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Pictures"), relativePath: MediaRelativePath(rawValue: "large.jpg"))
        let small = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Pictures"), relativePath: MediaRelativePath(rawValue: "small.png"))

        try view.setContent(image: image(edge: 8000), nativeLongEdge: 8000, assetID: large)
        try view.setContent(image: image(edge: 64), nativeLongEdge: 64, assetID: small)

        #expect(view.minMagnification == view.fitMagnification)
        #expect(view.maxMagnification >= view.minMagnification)
        #expect(view.minMagnification > 1)

        try view.setContent(image: image(edge: 8000), nativeLongEdge: 8000, assetID: large)
        #expect(view.minMagnification == view.fitMagnification)
        #expect(view.maxMagnification == 1)
    }
}
