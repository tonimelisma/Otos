import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Image renderer guide
///
/// The one place a still photo's pixels are made from its original (ADR 0035). A RAW
/// file is developed by `CIRAWFilter` with the newest decoder the file supports — RAW9
/// where Apple offers it, otherwise RAW8 — so the grid, the loupe and every product
/// derived from them show the same rendering; any other still is decoded by Image I/O
/// with its orientation applied. The result is an 8-bit Display P3 bitmap.
///
/// Rendering is blocking CPU and GPU work, so it leaves every actor on a named serial
/// queue (ADR 0032 rule 6). There are two lanes, each rendering one image at a time:
/// `background` for enrichment and `interactive` for what the user is looking at, so a
/// backlog of enrichment renders never queues in front of the photo on screen, and at
/// most two RAW developments — 160–340 MB each, measured — are in memory at once.
///
/// The caller has already checked that the original's bytes are local; reading a
/// dataless file here would block on its download.
final nonisolated class ImageRenderer: Sendable {
    /// Which decoder produced a rendering — recorded so a product can say how it was made.
    enum Decoder: String, Sendable {
        case raw9
        case raw8
        /// A RAW file whose camera only an older decoder supports.
        case rawOther
        case imageIO
    }

    struct Rendered: Sendable {
        /// An immutable 8-bit Display P3 bitmap.
        let image: CGImage
        let decoder: Decoder
        /// The original's oriented full-resolution size, for the loupe's 100% document.
        let nativePixelSize: CGSize
    }

    enum RenderError: Error {
        case unreadable
        case renderFailed
    }

    static let background = ImageRenderer(lane: "background")
    static let interactive = ImageRenderer(lane: "interactive")

    private let lane: String
    private let queue: DispatchQueue

    private init(lane: String) {
        self.lane = lane
        queue = DispatchQueue(label: "net.melisma.Otos.render.\(lane)", qos: lane == "interactive" ? .userInitiated : .utility)
    }

    /// Renders `url` with `recipe` applied so the edited photo's long edge is at most
    /// `longEdge`, or at full size when nil. A cropped photo is developed from a frame
    /// large enough for its crop to reach that size.
    func render(_ url: URL, longEdge: Int?, recipe: EditRecipe = .neutral) async throws -> Rendered {
        let lane = lane
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let start = ContinuousClock.now
                let signpost = OtosSignpost.rendering.beginInterval("ImageRender")
                defer { OtosSignpost.rendering.endInterval("ImageRender", signpost) }
                do {
                    let rendered = try Self.renderNow(url, longEdge: longEdge, recipe: recipe)
                    OtosLog.rendering.noticeOperation("render.still", phase: "finish", fields: [
                        "lane": lane,
                        "decoder": rendered.decoder.rawValue,
                        "width": "\(rendered.image.width)",
                        "height": "\(rendered.image.height)",
                        "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
                        "path": url.path(percentEncoded: false),
                    ])
                    continuation.resume(returning: rendered)
                } catch {
                    OtosLog.rendering.errorOperation("render.still", phase: "failed", fields: [
                        "lane": lane,
                        "path": url.path(percentEncoded: false),
                        "error": String(describing: error),
                    ])
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func isRAW(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) == true
    }

    private static func renderNow(_ url: URL, longEdge: Int?, recipe: EditRecipe) throws -> Rendered {
        if isRAW(url) {
            return try developRAW(url, longEdge: longEdge, recipe: recipe)
        }
        let decoded = try decodeImage(url, outputLongEdge: longEdge, recipe: recipe)
        guard !recipe.isNeutral else {
            return decoded
        }
        let developed = applying(recipe, toDevelopedRAW: false, CIImage(cgImage: decoded.image))
        let adjusted = applyingEffects(recipe, applyingGeometry(recipe, developed))
        return try Rendered(image: bitmap(adjusted), decoder: decoded.decoder, nativePixelSize: decoded.nativePixelSize)
    }

    /// The RAW's oriented full-resolution size: its sensor size, turned when its
    /// orientation (5–8) rotates it a quarter.
    static func orientedNativeSize(_ filter: CIRAWFilter) -> CGSize {
        let native = filter.nativeSize
        return filter.orientation.rawValue >= 5 ? CGSize(width: native.height, height: native.width) : native
    }

    /// The scale factor that develops the RAW so the edited photo's long edge is at most
    /// `outputLongEdge`: a crop keeps a fraction of the frame, so the frame is developed
    /// that much larger, never beyond full resolution.
    static func rawScaleFactor(_ filter: CIRAWFilter, outputLongEdge: Int?, recipe: EditRecipe) -> Float {
        let native = orientedNativeSize(filter)
        let nativeLongEdge = max(native.width, native.height)
        guard let outputLongEdge, nativeLongEdge > 0 else {
            return 1
        }
        let fraction = recipe.cropLongEdgeFraction(ofOriginal: native)
        return Float(min(1, Double(outputLongEdge) / (Double(nativeLongEdge) * fraction)))
    }

    /// Opens a RAW for development with the newest decoder the file supports, scaled for
    /// an edited long edge of at most `outputLongEdge`.
    static func openRAW(
        _ url: URL,
        outputLongEdge: Int?,
        recipe: EditRecipe
    ) throws -> (filter: CIRAWFilter, decoder: Decoder) {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw RenderError.unreadable
        }
        let decoder: Decoder
        if filter.supportedDecoderVersions.contains(.version9) {
            filter.decoderVersion = .version9
            decoder = .raw9
        } else if filter.supportedDecoderVersions.contains(.version8) {
            filter.decoderVersion = .version8
            decoder = .raw8
        } else {
            decoder = .rawOther
        }
        filter.scaleFactor = rawScaleFactor(filter, outputLongEdge: outputLongEdge, recipe: recipe)
        return (filter, decoder)
    }

    /// The developed image for `recipe`. Exposure is set on the filter, where it acts on
    /// the RAW data; everything after is applied to the developed image. Setting a
    /// property before each read matters: under RAW9 below a 0.5 scale factor a second
    /// read of an unchanged filter returns an image at half the requested size, and any
    /// property change restores it (research 2026-10-24).
    static func developed(_ filter: CIRAWFilter, recipe: EditRecipe) throws -> CIImage {
        filter.scaleFactor = filter.scaleFactor
        filter.exposure = Float(recipe.exposure)
        if let temperature = recipe.temperature {
            filter.neutralTemperature = Float(temperature)
        }
        if let tint = recipe.tint {
            filter.neutralTint = Float(tint)
        }
        // Detail and Optics act in the RAW pipeline when the decoder supports them; nil
        // leaves the decoder's own amount.
        if let sharpening = recipe.sharpening, filter.isSharpnessSupported {
            filter.sharpnessAmount = Float(sharpening / 100)
        }
        if let noise = recipe.noiseReduction, filter.isLuminanceNoiseReductionSupported {
            filter.luminanceNoiseReductionAmount = Float(noise / 100)
        }
        if let color = recipe.colorNoiseReduction, filter.isColorNoiseReductionSupported {
            filter.colorNoiseReductionAmount = Float(color / 100)
        }
        if let detail = recipe.detail, filter.isDetailSupported {
            filter.detailAmount = Float(detail / 100 * 3)
        }
        if let moire = recipe.moireReduction, filter.isMoireReductionSupported {
            filter.moireReductionAmount = Float(moire / 100)
        }
        if let lens = recipe.lensCorrection, filter.isLensCorrectionSupported {
            filter.isLensCorrectionEnabled = lens
        }
        guard let image = filter.outputImage else {
            throw RenderError.renderFailed
        }
        return applying(recipe, toDevelopedRAW: true, image)
    }

    /// Applies the recipe with the Core Image filters macOS provides (ADR 0036): white
    /// balance and exposure first, for a still that is not a RAW (a RAW's are applied in
    /// its pipeline), then contrast, highlights and shadows, vibrance, and saturation.
    /// A neutral value applies no filter.
    static func applying(_ recipe: EditRecipe, toDevelopedRAW isRAW: Bool, _ image: CIImage) -> CIImage {
        var output = image
        if !isRAW, recipe.temperature != nil || recipe.tint != nil {
            output = relativeWhiteBalance(temperature: recipe.temperature ?? 0, tint: recipe.tint ?? 0, output)
        }
        if !isRAW, recipe.exposure != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = output
            exposure.ev = Float(recipe.exposure)
            output = exposure.outputImage ?? output
        }
        if !isRAW, let noise = recipe.noiseReduction, noise > 0 {
            // Noise reduction alone: its own sharpening is left to the Sharpening control.
            let reduction = CIFilter.noiseReduction()
            reduction.inputImage = output
            reduction.noiseLevel = Float(noise / 100 * 0.1)
            reduction.sharpness = 0
            output = reduction.outputImage ?? output
        }
        if !isRAW, let sharpening = recipe.sharpening, sharpening > 0 {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = output
            sharpen.sharpness = Float(sharpening / 100)
            output = sharpen.outputImage ?? output
        }
        if recipe.contrast != 0 || recipe.saturation != 0 {
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.contrast = Float(1 + recipe.contrast / 200)
            controls.saturation = Float(1 + recipe.saturation / 100)
            output = controls.outputImage ?? output
        }
        // Highlights down and Shadows use Core Image's local tone filter. It cannot raise
        // highlights (an amount above 1 changes nothing, measured), so Highlights up lifts
        // the upper tones with a curve that keeps white at white, as Lightroom's does.
        if recipe.highlights < 0 || recipe.shadows != 0 {
            let tones = CIFilter.highlightShadowAdjust()
            tones.inputImage = output
            tones.highlightAmount = Float(1 + min(recipe.highlights, 0) / 100)
            tones.shadowAmount = Float(recipe.shadows / 100)
            output = tones.outputImage ?? output
        }
        if recipe.highlights > 0 {
            let lift = recipe.highlights / 100
            let curve = CIFilter.toneCurve()
            curve.inputImage = output
            curve.point0 = CGPoint(x: 0, y: 0)
            curve.point1 = CGPoint(x: 0.25, y: 0.25)
            curve.point2 = CGPoint(x: 0.5, y: 0.5 + 0.04 * lift)
            curve.point3 = CGPoint(x: 0.75, y: 0.75 + 0.14 * lift)
            curve.point4 = CGPoint(x: 1, y: 1)
            output = curve.outputImage ?? output
        }
        if recipe.vibrance != 0 {
            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = output
            vibrance.amount = Float(recipe.vibrance / 100)
            output = vibrance.outputImage ?? output
        }
        return output
    }

    /// A still's relative white balance: the image is treated as lit by a neutral one
    /// mired cooler per step of `temperature` (warmer output for a positive value) and
    /// one `CITemperatureAndTint` tint unit per step of `tint` (magenta for positive),
    /// mapped to D65. Measured on a mid gray: ±100 moves it from r/b 0.41/0.67 to 0.56/0.38
    /// (research 2026-10-25, white balance and geometry probes).
    static func relativeWhiteBalance(temperature: Double, tint: Double, _ image: CIImage) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 1_000_000 / (d65Mired - temperature), y: tint)
        filter.targetNeutral = CIVector(x: 1_000_000 / d65Mired, y: 0)
        return filter.outputImage ?? image
    }

    private static let d65Mired = 1_000_000 / 6500.0

    /// Applies the recipe's geometry (`EditGeometry`) to a developed, oriented image.
    static func applyingGeometry(_ recipe: EditRecipe, _ image: CIImage) -> CIImage {
        guard recipe.hasGeometry else {
            return image
        }
        let developed = atOrigin(image)
        let geometry = EditGeometry(recipe: recipe, developedSize: developed.extent.size)
        let frame = CGRect(origin: .zero, size: geometry.frameSize)
        // The edge is clamped before the transform so straightening samples the photo's
        // own edge pixels at the frame's border instead of transparency.
        let placed = developed.clampedToExtent().transformed(by: geometry.transform)
        return atOrigin(placed.cropped(to: geometry.cropRect.integral.intersection(frame)))
    }

    /// Applies the recipe's Effects to the edited, cropped photo: a vignette that follows
    /// the photo's shape. The photo is scaled to a square, `CIVignetteEffect` (a circle) is
    /// applied about its center, and it is scaled back, so the vignette is an ellipse fitted
    /// to the frame, as Lightroom's post-crop vignette is.
    static func applyingEffects(_ recipe: EditRecipe, _ image: CIImage) -> CIImage {
        guard recipe.vignette != 0, image.extent.width > 0, image.extent.height > 0 else {
            return image
        }
        let photo = atOrigin(image)
        let size = photo.extent.size
        let squeeze = size.height / size.width
        let square = photo.transformed(by: CGAffineTransform(scaleX: squeeze, y: 1))
        let side = size.height
        let vignette = CIFilter.vignetteEffect()
        vignette.inputImage = square
        vignette.center = CGPoint(x: side / 2, y: side / 2)
        // Midpoint 0…100 moves the start from a quarter to the whole of the half-diagonal.
        vignette.radius = Float(side / 2 * 2.0.squareRoot() * (0.25 + 0.75 * recipe.vignetteMidpoint / 100))
        vignette.falloff = Float(0.05 + 0.95 * recipe.vignetteFeather / 100)
        // Negative darkens the corners in Lightroom; positive intensity darkens in Core Image.
        vignette.intensity = Float(-recipe.vignette / 100)
        let applied = vignette.outputImage ?? square
        return applied
            .transformed(by: CGAffineTransform(scaleX: 1 / squeeze, y: 1))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func atOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    private static func developRAW(_ url: URL, longEdge: Int?, recipe: EditRecipe) throws -> Rendered {
        let (filter, decoder) = try openRAW(url, outputLongEdge: longEdge, recipe: recipe)
        let image = try applyingEffects(recipe, applyingGeometry(recipe, developed(filter, recipe: recipe)))
        return try Rendered(image: bitmap(image), decoder: decoder, nativePixelSize: orientedNativeSize(filter))
    }

    /// Decodes a still that is not a RAW, oriented, large enough for the recipe's edited
    /// long edge to reach `outputLongEdge` (the whole original when nil).
    static func decodeImage(_ url: URL, outputLongEdge: Int?, recipe: EditRecipe) throws -> Rendered {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else {
            throw RenderError.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let nativeLongEdge = max(width, height)
        guard nativeLongEdge > 0 else {
            throw RenderError.unreadable
        }
        let native = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let fraction = recipe.cropLongEdgeFraction(ofOriginal: native)
        let decodeLongEdge = outputLongEdge.map { Int((Double($0) / fraction).rounded(.up)) } ?? nativeLongEdge
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(decodeLongEdge, nativeLongEdge),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw RenderError.renderFailed
        }
        return Rendered(image: image, decoder: .imageIO, nativePixelSize: native)
    }

    /// Renders every pixel into an 8-bit Display P3 bitmap. `createCGImage` may return an
    /// image that renders lazily on first draw; the bitmap makes the work happen here, on
    /// the lane, rather than wherever the image is first drawn.
    static func bitmap(
        _ image: CIImage,
        context: CIContext = CIContext(options: [.cacheIntermediates: false])
    ) throws -> CGImage {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) else {
            throw RenderError.renderFailed
        }
        let rowBytes = width * 4
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { buffer in
            context.render(
                image,
                toBitmap: buffer.baseAddress!,
                rowBytes: rowBytes,
                bounds: extent,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: rowBytes,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else {
            throw RenderError.renderFailed
        }
        return cgImage
    }
}
