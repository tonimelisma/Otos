import CoreImage
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
    }

    private let queue = DispatchSerialQueue(label: "net.melisma.Otos.render.edit", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: true])
    private var open: OpenPhoto?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
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

    /// Lets go of the open photo, when editing moves to another photo or ends.
    func close() {
        open = nil
        context.clearCaches()
    }

    private func developed(_ url: URL, recipe: EditRecipe) throws -> CIImage {
        let photo = try openPhoto(url)
        switch photo.source {
        case let .image(image):
            return ImageRenderer.applying(recipe, includingExposure: true, to: image)
        case let .raw(filter):
            let image = try ImageRenderer.developed(filter, recipe: recipe)
            // RAW9 can hand back a half-size image on a repeated read; a fresh filter reads
            // correctly once (research 2026-10-24).
            guard max(image.extent.width, image.extent.height) < photo.expectedLongEdge * 0.75 else {
                return image
            }
            let (fresh, _) = try ImageRenderer.openRAW(url, longEdge: ThumbnailStore.previewMaxPixelSize)
            open = OpenPhoto(url: url, source: .raw(fresh), expectedLongEdge: photo.expectedLongEdge)
            return try ImageRenderer.developed(fresh, recipe: recipe)
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
            photo = OpenPhoto(url: url, source: .raw(filter), expectedLongEdge: min(Double(longEdge), native))
        } else {
            let decoded = try ImageRenderer.decodeImage(url, longEdge: longEdge)
            photo = OpenPhoto(
                url: url,
                source: .image(CIImage(cgImage: decoded.image)),
                expectedLongEdge: Double(max(decoded.image.width, decoded.image.height))
            )
        }
        open = photo
        return photo
    }
}
