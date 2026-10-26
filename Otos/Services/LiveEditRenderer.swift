import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import OSLog

/// Live edit renderer guide
///
/// Renders the photo being edited each time a control moves (ADR 0036). The first render
/// of a photo opens it — a `CIRAWFilter` for a RAW, a decoded image otherwise — and keeps
/// it, with one `CIContext` that caches intermediates, for every later render of the
/// same photo. That reuse is what keeps a slider change in tens of milliseconds instead
/// of the second a fresh development takes (research 2026-10-24: 20–180 ms after the
/// first render).
///
/// An actor whose executor is its own serial queue: development is blocking CPU and GPU
/// work, and it runs on that queue rather than on a shared executor (ADR 0032 rule 6).
/// Its state — the open photo and the context — is not `Sendable` and never leaves it.
///
/// Renders are at the stored preview's size, so the image shown while dragging is the
/// one the photo's preview will be once the edit is saved, and `RenderedEditImages`
/// stages exactly that for the store. The caller has already made the original local.
/// A saved recipe's render: the image the pane shows, and the preview and thumbnail
/// staged from it for the store to promote.
nonisolated struct RenderedEditImages: Sendable {
    let image: CGImage
    let preview: StagedDerivedImage
    let thumbnail: StagedDerivedImage

    /// Encodes and writes the preview and thumbnail of `image`. Encoding is not rendering:
    /// it runs on the caller's executor, never on the renderer's queue, so a save's
    /// encode does not hold up the next live render.
    static func staging(_ image: CGImage, id: MediaAssetID, directory: URL) throws -> RenderedEditImages {
        let preview = try ThumbnailStore.stagePreview(
            image, finalRelativeName: ThumbnailStore.previewRelativeName(for: id), in: directory
        )
        do {
            let thumbnail = try ThumbnailStore.stage(
                ThumbnailStore.scaled(image, toLongEdge: ThumbnailStore.maxPixelSize),
                finalRelativeName: ThumbnailStore.relativeName(for: id),
                in: directory
            )
            return RenderedEditImages(image: image, preview: preview, thumbnail: thumbnail)
        } catch {
            ThumbnailStore.discard(preview, in: directory)
            throw error
        }
    }
}

actor LiveEditRenderer {
    private enum Source {
        case raw(CIRAWFilter)
        /// A decoded still and the long edge it was decoded at.
        case image(CIImage, decodedLongEdge: Int)
    }

    private struct OpenPhoto {
        let url: URL
        var source: Source
        /// The original's oriented full-resolution size.
        let nativeSize: CGSize
        let facts: EditPhotoFacts
    }

    private let queue = DispatchSerialQueue(label: "net.melisma.Otos.render.edit", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: true])
    private var open: OpenPhoto?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Opens the photo at `url`, if it is not the one open, and reports its facts and
    /// upright size.
    func open(_ url: URL) throws -> OpenedEditPhoto {
        let photo = try openPhoto(url)
        return OpenedEditPhoto(facts: photo.facts, pixelSize: photo.nativeSize)
    }

    /// The photo at `url` with `recipe` applied, at the preview's size.
    func render(_ url: URL, recipe: EditRecipe) throws -> CGImage {
        let start = ContinuousClock.now
        let image = try ImageRenderer.bitmap(developed(url, recipe: recipe), context: context)
        // The size is logged because the scale factor decides it, and a wrong one costs a
        // fresh development (research 2026-10-26-live-edit-latency).
        OtosLog.rendering.debugOperation("render.liveEdit", phase: "finish", fields: [
            "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
            "width": "\(image.width)", "height": "\(image.height)",
            "path": url.path(percentEncoded: false),
        ])
        return image
    }

    /// The white balance that makes the photo neutral at `point` of the photo as it is
    /// shown — edited with `shown`'s geometry — given as a fraction of its width and height
    /// from the top-left corner. The point is mapped back through that geometry to the
    /// developed photo (`EditGeometry`), so a turned, straightened or cropped photo picks
    /// the pixel under the click.
    ///
    /// A RAW asks its pipeline (`CIRAWFilter.neutralLocation`, which takes a point in the
    /// oriented, scaled output with a bottom-left origin; measured 2026-10-25). Any other
    /// still samples the original's color there and solves for the relative temperature
    /// and tint that make it gray.
    func neutralWhiteBalance(
        _ url: URL,
        at point: CGPoint,
        shown: EditRecipe
    ) throws -> (temperature: Double, tint: Double) {
        let developed = try developedImage(url, recipe: shown)
        let geometry = EditGeometry(recipe: shown, developedSize: developed.extent.size)
        let location = geometry.developedPoint(atEditedFraction: point)
        guard let photo = open else {
            throw ImageRenderer.RenderError.renderFailed
        }
        switch photo.source {
        case let .raw(filter):
            filter.neutralLocation = CGPoint(
                x: developed.extent.minX + location.x,
                y: developed.extent.minY + location.y
            )
            return (Double(filter.neutralTemperature), Double(filter.neutralTint))
        case let .image(image, _):
            let sample = try sampledColor(image, at: location)
            return try relativeWhiteBalanceNeutralizing(sample)
        }
    }

    /// Lets go of the open photo, when editing moves to another photo or ends.
    func close() {
        open = nil
        context.clearCaches()
    }

    private func developed(_ url: URL, recipe: EditRecipe) throws -> CIImage {
        try ImageRenderer.applyingEffects(recipe, ImageRenderer.applyingGeometry(recipe, developedImage(url, recipe: recipe)))
    }

    /// The open photo developed with `recipe`'s adjustments but not its geometry, at the
    /// size `recipe`'s crop needs for its edited long edge to reach the preview's.
    private func developedImage(_ url: URL, recipe: EditRecipe) throws -> CIImage {
        var photo = try openPhoto(url)
        let previewLongEdge = ThumbnailStore.previewMaxPixelSize
        switch photo.source {
        case let .image(image, decodedLongEdge):
            let nativeLongEdge = Int(max(photo.nativeSize.width, photo.nativeSize.height))
            let fraction = recipe.cropLongEdgeFraction(ofOriginal: photo.nativeSize)
            let needed = min(nativeLongEdge, Int((Double(previewLongEdge) / fraction).rounded(.up)))
            guard abs(needed - decodedLongEdge) > 1 else {
                return ImageRenderer.applying(recipe, toDevelopedRAW: false, image)
            }
            // A crop changed how much of the frame is kept: decode again at the size it needs.
            let decoded = try ImageRenderer.decodeImage(url, outputLongEdge: previewLongEdge, recipe: recipe)
            let redecoded = CIImage(cgImage: decoded.image)
            photo.source = .image(redecoded, decodedLongEdge: max(decoded.image.width, decoded.image.height))
            open = photo
            context.clearCaches()
            return ImageRenderer.applying(recipe, toDevelopedRAW: false, redecoded)
        case let .raw(filter):
            // The open filter keeps whatever white balance the last render set, so as shot
            // is set back explicitly rather than left to the filter's default.
            var resolved = recipe
            resolved.temperature = recipe.temperature ?? photo.facts.asShotTemperature
            resolved.tint = recipe.tint ?? photo.facts.asShotTint
            resolved.sharpening = recipe.sharpening ?? photo.facts.rawDetail[.sharpening]
            resolved.noiseReduction = recipe.noiseReduction ?? photo.facts.rawDetail[.noiseReduction]
            resolved.colorNoiseReduction = recipe.colorNoiseReduction ?? photo.facts.rawDetail[.colorNoiseReduction]
            resolved.detail = recipe.detail ?? photo.facts.rawDetail[.detail]
            resolved.moireReduction = recipe.moireReduction ?? photo.facts.rawDetail[.moireReduction]
            resolved.lensCorrection = recipe.lensCorrection ?? photo.facts.lensCorrectionDefault
            let scale = ImageRenderer.rawScaleFactor(
                nativeSize: photo.nativeSize, outputLongEdge: previewLongEdge, recipe: recipe
            )
            filter.scaleFactor = scale
            let expectedLongEdge = Double(scale) * Double(max(photo.nativeSize.width, photo.nativeSize.height))
            let image = try ImageRenderer.developed(filter, recipe: resolved)
            // RAW9 can hand back a half-size image on a repeated read; a fresh filter reads
            // correctly once (research 2026-10-24).
            guard max(image.extent.width, image.extent.height) < expectedLongEdge * 0.75 else {
                return image
            }
            let fresh = try ImageRenderer.openRAW(url, outputLongEdge: previewLongEdge, recipe: recipe).filter
            photo.source = .raw(fresh)
            open = photo
            return try ImageRenderer.developed(fresh, recipe: resolved)
        }
    }

    private func openPhoto(_ url: URL) throws -> OpenPhoto {
        if let open, open.url == url {
            return open
        }
        context.clearCaches()
        let longEdge = ThumbnailStore.previewMaxPixelSize
        let photo: OpenPhoto
        if ImageRenderer.isRAW(url) {
            let opened = try ImageRenderer.openRAW(url, outputLongEdge: longEdge, recipe: .neutral)
            photo = OpenPhoto(
                url: url,
                source: .raw(opened.filter),
                nativeSize: opened.nativeSize,
                facts: Self.rawFacts(opened.filter)
            )
        } else {
            let decoded = try ImageRenderer.decodeImage(url, outputLongEdge: longEdge, recipe: .neutral)
            photo = OpenPhoto(
                url: url,
                source: .image(
                    CIImage(cgImage: decoded.image),
                    decodedLongEdge: max(decoded.image.width, decoded.image.height)
                ),
                nativeSize: decoded.nativePixelSize,
                facts: .still
            )
        }
        open = photo
        return photo
    }

    /// What a just-opened RAW's filter says before any recipe touches it: its as-shot white
    /// balance, the Detail amounts its decoder supports, and its lens correction default.
    private static func rawFacts(_ filter: CIRAWFilter) -> EditPhotoFacts {
        var detail: [EditControl: Double] = [:]
        if filter.isSharpnessSupported {
            detail[.sharpening] = Double(filter.sharpnessAmount) * 100
        }
        if filter.isLuminanceNoiseReductionSupported {
            detail[.noiseReduction] = Double(filter.luminanceNoiseReductionAmount) * 100
        }
        if filter.isColorNoiseReductionSupported {
            detail[.colorNoiseReduction] = Double(filter.colorNoiseReductionAmount) * 100
        }
        if filter.isDetailSupported {
            detail[.detail] = Double(filter.detailAmount) / 3 * 100
        }
        if filter.isMoireReductionSupported {
            detail[.moireReduction] = Double(filter.moireReductionAmount) * 100
        }
        return EditPhotoFacts(
            isRAW: true,
            asShotTemperature: Double(filter.neutralTemperature),
            asShotTint: Double(filter.neutralTint),
            rawDetail: detail,
            lensCorrectionDefault: filter.isLensCorrectionSupported ? filter.isLensCorrectionEnabled : nil
        )
    }

    /// The mean color of a 5-pixel square around `point` (the image's own coordinates,
    /// y up), as the one-pixel image `CIAreaAverage` produces.
    private func sampledColor(_ image: CIImage, at point: CGPoint) throws -> CIImage {
        let extent = image.extent
        let center = CGPoint(x: extent.minX + point.x, y: extent.minY + point.y)
        let area = CIFilter.areaAverage()
        area.inputImage = image
        area.extent = CGRect(x: center.x - 2, y: center.y - 2, width: 5, height: 5).intersection(extent)
        guard let average = area.outputImage else {
            throw ImageRenderer.RenderError.renderFailed
        }
        return average
    }

    /// Solves, by Newton steps with a numeric Jacobian, for the relative temperature and
    /// tint under which the one-pixel `swatch` renders gray. Each step renders three
    /// one-pixel images; five steps converge for any cast inside the sliders' range. The
    /// answer is clamped to that range, so a cast stronger than it can correct goes as far
    /// as the sliders go.
    private func relativeWhiteBalanceNeutralizing(_ swatch: CIImage) throws -> (temperature: Double, tint: Double) {
        func cast(_ temperature: Double, _ tint: Double) throws -> (Double, Double) {
            let rgb = try pixel(ImageRenderer.relativeWhiteBalance(temperature: temperature, tint: tint, swatch))
            // A black point has no cast to measure; the pick fails rather than reading as gray.
            guard rgb.green > 0 else { throw ImageRenderer.RenderError.renderFailed }
            return (rgb.red / rgb.green - 1, rgb.blue / rgb.green - 1)
        }
        var temperature = 0.0
        var tint = 0.0
        let delta = 1.0
        for _ in 0 ..< 5 {
            let base = try cast(temperature, tint)
            let byTemperature = try cast(temperature + delta, tint)
            let byTint = try cast(temperature, tint + delta)
            // Jacobian of (red cast, blue cast) by (temperature, tint).
            let redByTemperature = (byTemperature.0 - base.0) / delta
            let redByTint = (byTint.0 - base.0) / delta
            let blueByTemperature = (byTemperature.1 - base.1) / delta
            let blueByTint = (byTint.1 - base.1) / delta
            let determinant = redByTemperature * blueByTint - redByTint * blueByTemperature
            guard abs(determinant) > 1e-12 else { break }
            temperature -= (blueByTint * base.0 - redByTint * base.1) / determinant
            tint -= (redByTemperature * base.1 - blueByTemperature * base.0) / determinant
            temperature = min(max(temperature, -100), 100)
            tint = min(max(tint, -100), 100)
        }
        return (temperature.rounded(), tint.rounded())
    }

    private struct LinearRGB {
        let red: Double
        let green: Double
        let blue: Double
    }

    private func pixel(_ image: CIImage) throws -> LinearRGB {
        var rgba = [Float](repeating: 0, count: 4)
        context.render(
            image,
            toBitmap: &rgba,
            rowBytes: 16,
            bounds: CGRect(x: image.extent.minX, y: image.extent.minY, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: Self.linearSRGB
        )
        guard rgba[0].isFinite, rgba[1].isFinite, rgba[2].isFinite else {
            throw ImageRenderer.RenderError.renderFailed
        }
        return LinearRGB(red: Double(rgba[0]), green: Double(rgba[1]), blue: Double(rgba[2]))
    }

    private static let linearSRGB = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
}
