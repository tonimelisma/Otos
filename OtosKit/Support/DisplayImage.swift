import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import IOSurface
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
    /// short): decoded whole and drawn once, upright and scaled, into a `DisplayImage`.
    /// A 12 MP JPEG at 2,560 pixels peaks at 86–92 MB this way, 103–111 MB by the thumbnail
    /// decode, and takes 58–62 ms rather than 84–89.
    case wholeDrawn

    /// The route for a rendering of an original with `header`, edited by `recipe`, whose long
    /// edge is `longEdge` at most (the whole original when nil).
    static func of(_ header: OriginalHeader?, longEdge: Int?, recipe: EditRecipe) -> OriginalRoute {
        guard let header, header.decoding == .scaledByHalves else {
            return .thumbnail
        }
        let decodeLongEdge = header.decodeLongEdge(output: longEdge, recipe: recipe)
        // A JPEG decodes at half of itself only when the half still covers the edge.
        guard max(header.width, header.height) / 2 < decodeLongEdge else {
            return .thumbnail
        }
        return .wholeDrawn
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
/// **The rule: a layer shows only a `DisplayImage`, and a `DisplayImage` holds its pixels when
/// it is made.** Its pixels are drawn, off the main actor, into an IOSurface of its own, 8-bit
/// premultiplied BGRA. Core Animation shows an IOSurface-backed image as it is, with no copy,
/// and the surface leaves the footprint when the image goes
/// (`docs/research/2026-11-16-full-size-view-memory.md`). Because they are already there, the
/// window's commit that first shows the image does no work for it.
///
/// Any other `CGImage` makes the main thread pay when a layer first shows it, in the window's
/// commit (`docs/research/2026-11-18-display-images-drawn-before-shown.md`):
/// - Image I/O's whole decode of a JPEG is an IOSurface whose pixels the JPEG decoder fills
///   only then, about 3.5 ms for each 256 px thumbnail, which turned every new row of a scroll
///   into a dropped frame.
/// - A bitmap context's image, or pixels in malloc or mapped memory, is copied and the copy
///   kept with the image (`docs/research/2026-11-16-tile-images-shown-once.md`).
///
/// The only way to make one is `draw`, which every other constructor goes through:
/// - **`decode`** reads a stored image file — a thumbnail, a loupe preview — decoded by Image
///   I/O at no more than the pixels it is shown at, and draws it. The pixels are as stored:
///   `ThumbnailStore` writes every derived image upright.
/// - **`shown`** draws a rendering made elsewhere: an original's decode, a developed RAW, a
///   video's poster.
/// - **`rendered`** renders a Core Image image, a live edit, straight into the surface.
/// - **`draw`** gives `body` a context over the new surface's pixels in the color space the
///   caller names: a cut Otos draws itself, such as a face tile. Drawing into pixels of its own
///   also keeps the image independent of what it was cut from (a `CGImage.cropping(to:)` holds
///   the whole decode it came from, `docs/research/2026-11-16-image-memory-while-used.md`).
///
/// `original` is the one decode of a still's original that is not a RAW, for both render lanes
/// (`ImageRenderer`), by the route its format and size call for (`OriginalRoute`).
///
/// They run on their caller's thread, and every caller runs them off the main actor.
nonisolated struct DisplayImage: Sendable {
    /// The image a layer or SwiftUI's `Image` shows: `surface`, wrapped without a copy.
    let cgImage: CGImage
    /// The surface `cgImage` shows, 8-bit premultiplied BGRA, filled when this was made:
    /// reading it runs no decoder.
    let surface: IOSurface

    private init(_ cgImage: CGImage, surface: IOSurface) {
        self.cgImage = cgImage
        self.surface = surface
    }

    var width: Int {
        cgImage.width
    }

    var height: Int {
        cgImage.height
    }

    /// The bytes its pixels hold.
    var byteCount: Int {
        surface.allocationSize
    }

    /// Whether `self` and `other` are the same image, not merely equal pixels.
    func isSame(as other: DisplayImage) -> Bool {
        cgImage === other.cgImage
    }

    /// The image file at `url`, at no more than `maxPixelEdge` on its long edge; nil when the
    /// file is missing or unreadable.
    static func decode(_ url: URL, maxPixelEdge: Int) -> DisplayImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        let decoded: CGImage? = if max(width, height) <= maxPixelEdge {
            CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else {
            CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelEdge,
                kCGImageSourceShouldCache: false,
            ] as CFDictionary)
        }
        // Drawing it is what decodes it: the decode's own pixels exist only for the draw.
        return decoded.flatMap(shown)
    }

    /// `image` drawn once into a `DisplayImage`, in its own color space when that is RGB and in
    /// sRGB otherwise (a grayscale or CMYK file). Nil when no surface can be made.
    static func shown(_ image: CGImage) -> DisplayImage? {
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return draw(width: image.width, height: image.height, colorSpace: colorSpace) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    /// `image`, a Core Image rendering such as a live edit, rendered by `context` straight into
    /// a `DisplayImage` in Display P3. Nil when its extent is empty or no surface can be made.
    static func rendered(_ image: CIImage, context: CIContext) -> DisplayImage? {
        let extent = image.extent.integral
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        return draw(width: Int(extent.width), height: Int(extent.height), colorSpace: colorSpace) { drawing in
            guard let pixels = drawing.data else { return }
            // The surface's rows run top-down, as a bitmap Core Image renders does.
            context.render(image, toBitmap: pixels, rowBytes: drawing.bytesPerRow, bounds: extent, format: .BGRA8, colorSpace: colorSpace)
        }
    }

    /// A still's original (not a RAW) decoded by `route` for a rendering whose long edge,
    /// upright, is `decodeLongEdge` at most (the whole original when nil); nil when Image I/O
    /// cannot decode it. The `wholeDrawn` route's upright draw is already a `DisplayImage`,
    /// returned with it so a pane shows it without drawing it again; a `wholeDrawn` original
    /// whose pixels are not RGB is decoded by the thumbnail route, which converts them.
    static func original(
        _ source: CGImageSource,
        header: OriginalHeader,
        decodeLongEdge: Int?,
        route: OriginalRoute
    ) -> (image: CGImage, drawn: DisplayImage?)? {
        let native = max(header.width, header.height)
        let edge = min(decodeLongEdge ?? native, native)
        func thumbnail() -> (image: CGImage, drawn: DisplayImage?)? {
            CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
            ] as CFDictionary).map { ($0, nil) }
        }
        switch route {
        case .thumbnail:
            return thumbnail()
        case .wholeDrawn:
            guard let whole = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  let colorSpace = whole.colorSpace, colorSpace.model == .rgb
            else {
                return thumbnail()
            }
            return upright(whole, orientation: header.orientation, longEdge: edge, colorSpace: colorSpace).map { ($0.cgImage, $0) }
        }
    }

    /// `image` turned upright by its EXIF `orientation` and scaled so its long edge is
    /// `longEdge`, drawn once into a `DisplayImage`.
    private static func upright(_ image: CGImage, orientation: Int, longEdge: Int, colorSpace: CGColorSpace) -> DisplayImage? {
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

    /// A `width` × `height` image of what `body` draws, in `colorSpace` (an RGB one), its
    /// pixels filled by the time this returns.
    static func draw(width: Int, height: Int, colorSpace: CGColorSpace, _ body: (CGContext) -> Void) -> DisplayImage? {
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
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr, let image,
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        else {
            return nil
        }
        return DisplayImage(image, surface: surface as IOSurface)
    }
}
