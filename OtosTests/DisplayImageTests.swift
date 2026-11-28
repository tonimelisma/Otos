import CoreImage
import CoreVideo
import Foundation
import ImageIO
import IOSurface
@testable import OtosKit
import Testing
import UniformTypeIdentifiers

/// A layer shows only a `DisplayImage`, and a `DisplayImage` holds its pixels when it is made
/// (APP-169). Scrolling on the test Mac stuttered on every new row because each tile's thumbnail
/// was Image I/O's whole decode of a JPEG, whose pixels the decoder fills only when Core
/// Animation first shows the image, in the window's commit on the main thread: about 3.5 ms a
/// tile (`docs/research/2026-11-18-display-images-drawn-before-shown.md`).
///
/// Each test reads the image's own surface, the memory a layer shows, which runs no decoder: a form whose pixels
/// are made when it is shown has none there to read. The colors are what the file holds, so
/// what a layer will show is already in the surface it shows.
@Suite(.testScope)
struct DisplayImageTests {
    // Validates: APP-091
    /// The grid's path: a stored thumbnail, decoded whole, holds its pixels when the tile
    /// store gets it.
    @Test func aStoredThumbnailHoldsItsPixelsWhenLoaded() throws {
        let directory = try makeTestDirectory()
        try Self.writeJPEG(width: 256, height: 192, red: 200, green: 40, blue: 30, to: directory.appending(path: "t.jpg"))
        let image = try #require(ThumbnailStore.load("t.jpg", in: directory))
        #expect(image.width == 256 && image.height == 192)
        try Self.expectFilled(image, near: (200, 40, 30))
    }

    // Validates: APP-091
    /// The loupe's path: a stored preview larger than the pane asks for is scaled by Image
    /// I/O and drawn, and holds its pixels when the loader gets it.
    @Test func aScaledDecodeHoldsItsPixelsWhenMade() throws {
        let directory = try makeTestDirectory()
        let url = directory.appending(path: "p.jpg")
        try Self.writeJPEG(width: 1024, height: 768, red: 30, green: 160, blue: 220, to: url)
        let image = try #require(DisplayImage.decode(url, maxPixelEdge: 300))
        #expect(max(image.width, image.height) <= 300)
        try Self.expectFilled(image, near: (30, 160, 220))
    }

    // Validates: APP-091
    /// A grayscale file has no RGB color space to draw in; it is drawn in sRGB.
    @Test func aGrayscaleFileIsDrawnInSRGB() throws {
        let directory = try makeTestDirectory()
        let url = directory.appending(path: "g.jpg")
        let gray = try #require(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        gray.setFillColor(gray: 0.5, alpha: 1)
        gray.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        try Self.write(#require(gray.makeImage()), to: url)
        let image = try #require(DisplayImage.decode(url, maxPixelEdge: .max))
        #expect(image.cgImage.colorSpace?.model == .rgb)
        try Self.expectFilled(image, near: (128, 128, 128))
    }

    // Validates: APP-091
    /// A live edit's Core Image rendering is rendered straight into the surface, upright.
    @Test func aCoreImageRenderingHoldsItsPixelsTopRowFirst() throws {
        // Red on the bottom half, blue on the top half, in Core Image's y-up space.
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 20, width: 40, height: 20))
        let image = try #require(DisplayImage.rendered(blue.composited(over: red), context: CIContext()))
        #expect(image.width == 40 && image.height == 40)
        let top = try Self.pixel(of: image, x: 20, y: 5)
        let bottom = try Self.pixel(of: image, x: 20, y: 35)
        #expect(top.blue > 200 && top.red < 40, "the first row is the top: \(top)")
        #expect(bottom.red > 200 && bottom.blue < 40, "the last row is the bottom: \(bottom)")
    }

    // MARK: - Helpers

    private static func expectFilled(_ image: DisplayImage, near expected: (Int, Int, Int)) throws {
        #expect(image.surface.pixelFormat == kCVPixelFormatType_32BGRA)
        for (x, y) in [(1, 1), (image.width / 2, image.height / 2), (image.width - 2, image.height - 2)] {
            let found = try pixel(of: image, x: x, y: y)
            #expect(abs(found.red - expected.0) <= 12 && abs(found.green - expected.1) <= 12 && abs(found.blue - expected.2) <= 12,
                    "pixel (\(x), \(y)) is \(found), the file holds \(expected)")
        }
    }

    private static func pixel(of image: DisplayImage, x: Int, y: Int) throws -> (red: Int, green: Int, blue: Int) {
        let surface = image.surface
        #expect(surface.lock(options: .readOnly, seed: nil) == kIOReturnSuccess)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let offset = y * surface.bytesPerRow + x * 4
        return (red: Int(base[offset + 2]), green: Int(base[offset + 1]), blue: Int(base[offset]))
    }

    private static func writeJPEG(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat, to url: URL) throws {
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        try write(#require(context.makeImage()), to: url)
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }
}
