import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

/// Display image guide
///
/// **The rule: every image Otos makes for a layer to show comes from here.** Such an image
/// keeps its pixels once, in an IOSurface of its own: Core Animation and SwiftUI show an
/// IOSurface-backed image as it is, and the surface leaves the footprint when the image goes.
/// Any other `CGImage` — a bitmap context's image, pixels in malloc or in mapped memory — is
/// copied by Core Animation for display, and the copy is kept with the image for as long as
/// the image lives, shown or not (`docs/research/2026-11-16-full-size-view-memory.md`,
/// `docs/research/2026-11-16-tile-images-shown-once.md`).
///
/// - **`decode`** reads a stored image file — a thumbnail, a loupe preview — at no more than
///   the pixels it is shown at. A file no larger than that is decoded whole by Image I/O,
///   which returns a JPEG in an IOSurface as its decoder writes it (YCbCr, about 1.6 bytes a
///   pixel), never drawn again. Neither form's pixels are filled when this returns: they are
///   filled when Core Animation first shows the image, in the window's commit (measured,
///   `docs/research/2026-11-16-tile-images-shown-once.md`). A larger one is scaled by Image I/O's thumbnail decode, which
///   returns a HEIC in an IOSurface. The pixels are as stored: `ThumbnailStore` writes every
///   derived image upright.
/// - **`draw`** gives `body` a context over a new IOSurface's pixels, 8-bit premultiplied
///   BGRA in the color space the caller names, and returns the image once `body` has drawn:
///   a cut Otos draws itself, such as a face tile. Drawing into pixels of its own also keeps
///   the image independent of what it was cut from (a `CGImage.cropping(to:)` holds the whole
///   decode it came from, `docs/research/2026-11-16-image-memory-while-used.md`).
///
/// Both run on their caller's thread, and every caller runs them off the main actor.
nonisolated enum DisplayImage {
    /// The image file at `url`, at no more than `maxPixelEdge` on its long edge; nil when the
    /// file is missing or unreadable.
    static func decode(_ url: URL, maxPixelEdge: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        if max(width, height) <= maxPixelEdge {
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelEdge,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// A `width` × `height` image of what `body` draws, in `colorSpace` (an RGB one).
    static func draw(width: Int, height: Int, colorSpace: CGColorSpace, _ body: (CGContext) -> Void) -> CGImage? {
        guard width > 0, height > 0, colorSpace.model == .rgb else { return nil }
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
            == kCVReturnSuccess,
            let buffer = created
        else {
            return nil
        }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        let drawn: Bool
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) {
            body(context)
            drawn = true
        } else {
            drawn = false
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard drawn else { return nil }
        // The image holds the buffer, and so its surface, until the last reference to the
        // image goes; nothing writes the pixels after this.
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr else { return nil }
        return image
    }
}
