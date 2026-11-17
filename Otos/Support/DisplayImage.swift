import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// How the one decode of a still's original makes its rendering, chosen per format and size by
/// what each route holds at its peak and how long it takes (measured on macOS 27,
/// `docs/research/2026-11-17-jpeg-decode-routes.md`).
nonisolated enum OriginalRoute: Hashable, Sendable {
    /// Image I/O's thumbnail decode at the asked size: a HEIC at that size, a JPEG at the
    /// smallest half of itself that covers it, any other format whole.
    case thumbnail
    /// A JPEG that Image I/O would decode whole for the asked size anyway (a half of it falls
    /// short): decoded whole and drawn once, upright and scaled, into an IOSurface of its own.
    /// A 12 MP JPEG at 2,560 pixels peaks at 86–92 MB this way, 103–111 MB by the thumbnail
    /// decode, and takes 58–62 ms rather than 84–89.
    case wholeDrawn
    /// The same JPEG, upright and unedited, for a pane to show: the whole image as Image I/O
    /// returns it, whose pixels are filled in the JPEG's own YCbCr layout in an IOSurface when
    /// a layer first shows it. A 12 MP JPEG peaks at 36–37 MB through its first showing,
    /// holds 18–19 MB, and is on screen in 17–19 ms. A preview to encode is drawn from its
    /// pixels twice (the preview, its thumbnail), so only a pane asks for it.
    case wholeShown

    /// The route for a rendering of an original with `header`, edited by `recipe`, whose long
    /// edge is `longEdge` at most (the whole original when nil); `forDisplay` when a pane
    /// shows the rendering as it is.
    static func of(_ header: OriginalHeader?, longEdge: Int?, recipe: EditRecipe, forDisplay: Bool) -> OriginalRoute {
        guard let header, header.decoding == .scaledByHalves else {
            return .thumbnail
        }
        let decodeLongEdge = header.decodeLongEdge(output: longEdge, recipe: recipe)
        // A JPEG decodes at half of itself only when the half still covers the edge.
        guard max(header.width, header.height) / 2 < decodeLongEdge else {
            return .thumbnail
        }
        return forDisplay && recipe.isNeutral && header.orientation == 1 ? .wholeShown : .wholeDrawn
    }
}

/// What a still original's header says, read without decoding it.
nonisolated struct OriginalHeader: Hashable, Sendable {
    let width: Int
    let height: Int
    /// The EXIF orientation, 1 (upright) when the file names none.
    let orientation: Int
    let decoding: DecodeCost.Decoding

    /// The original's size upright.
    var orientedSize: CGSize {
        orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// The long edge to decode for a rendering whose edited long edge is `output` at most: a
    /// crop needs more of the original to reach it. The whole original when `output` is nil.
    func decodeLongEdge(output: Int?, recipe: EditRecipe) -> Int {
        let native = max(width, height)
        guard let output else { return native }
        let fraction = recipe.cropLongEdgeFraction(ofOriginal: orientedSize)
        return Int((Double(output) / fraction).rounded(.up))
    }

    /// The header of the image `source` holds, of `type`; nil when it names no size.
    static func read(_ source: CGImageSource, type: UTType?) -> OriginalHeader? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else {
            return nil
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return OriginalHeader(width: width, height: height, orientation: orientation, decoding: DecodeCost.Decoding(type: type))
    }

    /// The header of the file at `url`, read off the caller's actor; nil when it cannot be read.
    @concurrent
    static func read(_ url: URL) async -> OriginalHeader? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return read(source, type: UTType(filenameExtension: url.pathExtension))
    }
}

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
/// - **`original`** is the one decode of a still's original that is not a RAW, for both render
///   lanes (`ImageRenderer`), by the route its format and size call for (`OriginalRoute`).
///
/// They run on their caller's thread, and every caller runs them off the main actor.
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

    /// A rendering of an original — Image I/O's scaled decode of a JPEG, a developed RAW, an
    /// edited still: pixels in ordinary memory, which Core Animation would copy for display
    /// and keep with the image — drawn once into an IOSurface of its own, shown as it is
    /// (`docs/research/2026-11-17-full-size-view-on-originals.md`). Nil when `image` has no
    /// RGB color space or no surface can be made.
    static func shown(_ image: CGImage) -> CGImage? {
        guard let colorSpace = image.colorSpace, colorSpace.model == .rgb else { return nil }
        return draw(width: image.width, height: image.height, colorSpace: colorSpace) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    /// A still's original (not a RAW) decoded by `route` for a rendering whose long edge,
    /// upright, is `decodeLongEdge` at most (the whole original when nil), and whether a layer
    /// shows it as it is, its pixels in an IOSurface of their own (a HEIC's thumbnail decode,
    /// either whole route); nil when Image I/O cannot decode it. A `wholeDrawn` original whose
    /// pixels are not RGB is decoded by the thumbnail route, which converts them.
    static func original(
        _ source: CGImageSource,
        header: OriginalHeader,
        decodeLongEdge: Int?,
        route: OriginalRoute
    ) -> (image: CGImage, isSurface: Bool)? {
        let native = max(header.width, header.height)
        let edge = min(decodeLongEdge ?? native, native)
        func thumbnail() -> (image: CGImage, isSurface: Bool)? {
            CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
            ] as CFDictionary).map { ($0, header.decoding == .atAskedSize) }
        }
        switch route {
        case .thumbnail:
            return thumbnail()
        case .wholeShown:
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                .map { ($0, true) }
        case .wholeDrawn:
            guard let whole = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  let colorSpace = whole.colorSpace, colorSpace.model == .rgb
            else {
                return thumbnail()
            }
            return upright(whole, orientation: header.orientation, longEdge: edge, colorSpace: colorSpace).map { ($0, true) }
        }
    }

    /// `image` turned upright by its EXIF `orientation` and scaled so its long edge is
    /// `longEdge`, drawn once into an IOSurface of its own.
    private static func upright(_ image: CGImage, orientation: Int, longEdge: Int, colorSpace: CGColorSpace) -> CGImage? {
        let source = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // Core Image's orientation transform, in the same y-up coordinates as a bitmap context;
        // making it reads no pixels.
        let turn = CIImage(cgImage: image).orientationTransform(forExifOrientation: Int32(orientation))
        let turned = source.applying(turn)
        let scale = Double(longEdge) / Double(max(turned.width, turned.height))
        let width = max(1, Int((turned.width * scale).rounded()))
        let height = max(1, Int((turned.height * scale).rounded()))
        return draw(width: width, height: height, colorSpace: colorSpace) { context in
            context.interpolationQuality = .high
            context.scaleBy(x: CGFloat(width) / turned.width, y: CGFloat(height) / turned.height)
            context.translateBy(x: -turned.minX, y: -turned.minY)
            context.concatenate(turn)
            context.draw(image, in: source)
        }
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
