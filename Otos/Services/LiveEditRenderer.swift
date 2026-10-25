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
/// one the photo's preview will be once the edit is saved, and `renderProducts` stages
/// exactly that for the store. The caller has already made the original local.
/// A saved recipe's render: the image the pane shows, and the preview and thumbnail
/// staged from it for the store to promote.
nonisolated struct RenderedEditImages: Sendable {
    let image: CGImage
    let preview: StagedDerivedImage
    let thumbnail: StagedDerivedImage
}

actor LiveEditRenderer {
    private enum Source {
        case raw(CIRAWFilter)
        case image(CIImage)
    }

    private struct OpenPhoto {
        let url: URL
        let source: Source
        let expectedLongEdge: Double
        let facts: EditPhotoFacts
    }

    private let queue = DispatchSerialQueue(label: "net.melisma.Otos.render.edit", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: true])
    private var open: OpenPhoto?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Opens the photo at `url`, if it is not the one open, and reports its facts.
    func open(_ url: URL) throws -> EditPhotoFacts {
        try openPhoto(url).facts
    }

    /// The photo at `url` with `recipe` applied, at the preview's size.
    func render(_ url: URL, recipe: EditRecipe) throws -> CGImage {
        let start = ContinuousClock.now
        let image = try ImageRenderer.bitmap(developed(url, recipe: recipe), context: context)
        OtosLog.rendering.debugOperation("render.liveEdit", phase: "finish", fields: [
            "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
            "path": url.path(percentEncoded: false),
        ])
        return image
    }

    /// The saved recipe's preview and thumbnail, staged for the store to promote, and the
    /// image they were made from for the pane to show meanwhile.
    func renderProducts(
        _ url: URL,
        recipe: EditRecipe,
        id: MediaAssetID,
        directory: URL
    ) throws -> RenderedEditImages {
        let image = try render(url, recipe: recipe)
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

    /// The white balance that makes the photo neutral at `point` — a fraction of the
    /// image's width and height from its top-left corner — as the recipe's temperature
    /// and tint.
    ///
    /// A RAW asks its pipeline (`CIRAWFilter.neutralLocation`, which takes a point in the
    /// oriented, scaled output with a bottom-left origin; measured 2026-10-25). Any other
    /// still samples the original's color there and solves for the relative temperature
    /// and tint that make it gray.
    func neutralWhiteBalance(_ url: URL, at point: CGPoint) throws -> (temperature: Double, tint: Double) {
        let photo = try openPhoto(url)
        switch photo.source {
        case let .raw(filter):
            guard let extent = filter.outputImage?.extent else {
                throw ImageRenderer.RenderError.renderFailed
            }
            filter.neutralLocation = CGPoint(
                x: extent.minX + point.x * extent.width,
                y: extent.minY + (1 - point.y) * extent.height
            )
            return (Double(filter.neutralTemperature), Double(filter.neutralTint))
        case let .image(image):
            let sample = try sampledColor(image, at: point)
            return try relativeWhiteBalanceNeutralizing(sample)
        }
    }

    /// Lets go of the open photo, when editing moves to another photo or ends.
    func close() {
        open = nil
        context.clearCaches()
    }

    private func developed(_ url: URL, recipe: EditRecipe) throws -> CIImage {
        let photo = try openPhoto(url)
        switch photo.source {
        case let .image(image):
            return ImageRenderer.applying(recipe, toDevelopedRAW: false, image)
        case let .raw(filter):
            // The open filter keeps whatever white balance the last render set, so as shot
            // is set back explicitly rather than left to the filter's default.
            var resolved = recipe
            resolved.temperature = recipe.temperature ?? photo.facts.asShotTemperature
            resolved.tint = recipe.tint ?? photo.facts.asShotTint
            let image = try ImageRenderer.developed(filter, recipe: resolved)
            // RAW9 can hand back a half-size image on a repeated read; a fresh filter reads
            // correctly once (research 2026-10-24).
            guard max(image.extent.width, image.extent.height) < photo.expectedLongEdge * 0.75 else {
                return image
            }
            let (fresh, _) = try ImageRenderer.openRAW(url, longEdge: ThumbnailStore.previewMaxPixelSize)
            open = OpenPhoto(
                url: url, source: .raw(fresh), expectedLongEdge: photo.expectedLongEdge, facts: photo.facts
            )
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
            let (filter, _) = try ImageRenderer.openRAW(url, longEdge: longEdge)
            let native = max(filter.nativeSize.width, filter.nativeSize.height)
            photo = OpenPhoto(
                url: url,
                source: .raw(filter),
                expectedLongEdge: min(Double(longEdge), native),
                facts: EditPhotoFacts(
                    isRAW: true,
                    asShotTemperature: Double(filter.neutralTemperature),
                    asShotTint: Double(filter.neutralTint)
                )
            )
        } else {
            let decoded = try ImageRenderer.decodeImage(url, longEdge: longEdge)
            photo = OpenPhoto(
                url: url,
                source: .image(CIImage(cgImage: decoded.image)),
                expectedLongEdge: Double(max(decoded.image.width, decoded.image.height)),
                facts: .still
            )
        }
        open = photo
        return photo
    }

    /// The mean color of a 5-pixel square around `point` (top-left fractions), as the
    /// one-pixel image `CIAreaAverage` produces.
    private func sampledColor(_ image: CIImage, at point: CGPoint) throws -> CIImage {
        let extent = image.extent
        let center = CGPoint(x: extent.minX + point.x * extent.width, y: extent.minY + (1 - point.y) * extent.height)
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
