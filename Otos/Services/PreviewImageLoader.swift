import CoreGraphics
import Foundation
import ImageIO
import OSLog
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Preview loading boundary used by `CatalogWindowViewModel`. Production uses
/// `PreviewImageLoader`; tests inject a controllable fake via constructor injection.
/// Explicitly nonisolated so actor-backed loaders can conform under MainActor-default
/// module isolation.
nonisolated protocol PreviewLoading: Sendable {
    func preview(for request: PreviewImageLoader.Request) async -> PreviewImageLoader.Outcome
    /// Returns once no decode under `root` is in flight, and refuses new ones there until
    /// `resume(under:)`: an eject must not find the loader holding a card file open.
    func quiesce(under root: LibraryRootPath) async
    func resume(under root: LibraryRootPath) async
}

/// Preview image loader guide
///
/// The loupe/compare analog of `EnrichmentCoordinator`'s byte-read role, and the app's
/// only full-size decode path (ADR 0016). Callers ask for a preview at a target long edge;
/// this actor asks the shared `MaterializationCoordinator` to make the original local
/// (`ensureLocal`, interactive, because the user has opened loupe/compare), re-checks
/// `FileMaterialization.status` immediately before every byte read, and returns a
/// downsampled `CGImage` or `.unavailable`.
///
/// Per-id in-flight work is coalesced. Stale results are rejected by the ViewModel's
/// expected-asset identity check — this actor returns whatever it decoded.
///
/// **What it holds.** A pane holds the image it shows (`PanePreview`), so the loader holds
/// only what a pane can come back to: the screen-sized decodes of the last
/// `retainedPhotos` photos asked for — the two Compare panes and the photo just left — so a
/// step back to the previous photo, or a slide back in Compare, paints at once. A
/// full-resolution decode, up to a few hundred megabytes for one photo, is held only by the
/// pane showing it; leaving that photo lets it go, and coming back asks for it again only
/// when the zoom does (APP-040). A hit requires `entry.longEdge >= request.targetLongEdge`
/// so a screen-size change re-decodes instead of upscaling. Each decoded image's pixels are
/// a region of their own (`2026-11-16-image-memory-while-used.md` §2), so what this lets go
/// leaves the footprint.
actor PreviewImageLoader: PreviewLoading {
    /// Two outcomes, because nothing downstream can act on a third.
    ///
    /// Interactive materialization persists until the bytes arrive or the request is
    /// cancelled (APP-023), so a non-image result means cancelled or genuinely absent —
    /// neither of which the caller retries. There is no "still downloading" outcome: it
    /// would only invite a re-request that restarts the attempt. The reason is still
    /// logged; it is just not a decision anyone makes.
    enum Outcome {
        /// The decode plus the source's native pixel size (oriented), when the source
        /// reports one — the loupe sizes its zoom document from it (APP-040).
        case image(CGImage, nativePixelSize: CGSize?)
        case unavailable
    }

    /// `Request.targetLongEdge` value asking for the full native resolution; the decode
    /// clamps it to the source's own long edge.
    static let fullResolution = Int.max

    struct Request {
        let id: MediaAssetID
        let detail: MediaTileDetail?
        let targetLongEdge: Int
    }

    /// The photos whose screen-sized decode is held: both Compare panes and the photo just
    /// left, so a return to it never waits.
    static let retainedPhotos = 3

    private struct CacheEntry {
        let image: CGImage
        let longEdge: Int
        let nativePixelSize: CGSize?
        /// The rendered edit revision the image shows (ADR 0036); a newer one misses.
        let revision: Int64
    }

    private let materializationRequester: any MaterializationRequesting
    private let status: @Sendable (URL) -> FileMaterializationStatus
    /// Where stored previews live (ADR 0035); nil for an in-memory catalog, which then
    /// always decodes the original.
    private let derivedImageDirectory: URL?
    private var cache: [MediaAssetID: CacheEntry] = [:]
    /// The held photos, least recently asked for first.
    private var cacheOrder: [MediaAssetID] = []
    /// One decode per asset in flight, remembered with the size it was asked for. A second
    /// request shares it only when that decode is at least as large as the one it needs;
    /// otherwise it would be handed a smaller image than it asked for.
    private struct InFlightDecode {
        let longEdge: Int
        let revision: Int64
        let task: Task<Outcome, Never>
    }

    private var inFlight: [MediaAssetID: InFlightDecode] = [:]
    /// Roots an eject is releasing. A request there is answered `.unavailable` without
    /// touching the file.
    private var quiescedRoots: Set<LibraryRootPath> = []

    init(
        status: @escaping @Sendable (URL) -> FileMaterializationStatus = FileMaterialization.status(of:),
        derivedImageDirectory: URL? = nil,
        materializationRequester: any MaterializationRequesting
    ) {
        self.status = status
        self.derivedImageDirectory = derivedImageDirectory
        self.materializationRequester = materializationRequester
    }

    /// Decodes (or materializes then decodes) a preview for `request.id`. Cached hits
    /// return immediately when the stored long edge is large enough. Concurrent requests
    /// for the same id share one in-flight task.
    func preview(for request: Request) async -> Outcome {
        guard !quiescedRoots.contains(request.id.libraryRootPath) else {
            OtosLog.mediaIO.notice(
                "op=preview.decode phase=refused reason=sourceQuiesced id=\(request.id.relativePath.rawValue, privacy: .public)"
            )
            return .unavailable
        }
        let revision = request.detail?.renderedRevision ?? 0
        if let cached = cache[request.id], cached.longEdge >= request.targetLongEdge, cached.revision == revision {
            touch(request.id)
            return .image(cached.image, nativePixelSize: cached.nativePixelSize)
        }
        if let existing = inFlight[request.id], existing.longEdge >= request.targetLongEdge,
           existing.revision == revision
        {
            return await existing.task.value
        }
        let task = Task(priority: .userInitiated) {
            await self.decode(request)
        }
        // A larger request replaces a smaller decode's entry; the smaller one finishes for
        // its own caller, and each caller removes only the entry it owns.
        inFlight[request.id] = InFlightDecode(longEdge: request.targetLongEdge, revision: revision, task: task)
        let outcome = await task.value
        if inFlight[request.id]?.longEdge == request.targetLongEdge, inFlight[request.id]?.revision == revision {
            inFlight[request.id] = nil
        }
        if request.targetLongEdge == Self.fullResolution {
            // The pane holds the full decode; the photo's screen-sized one stays the newest
            // held, the one a return to it paints.
            if cache[request.id] != nil {
                touch(request.id)
            }
        } else if case let .image(image, nativePixelSize) = outcome {
            insert(
                image, for: request.id, longEdge: request.targetLongEdge,
                nativePixelSize: nativePixelSize, revision: revision
            )
        }
        return outcome
    }

    func quiesce(under root: LibraryRootPath) async {
        quiescedRoots.insert(root)
        let running = inFlight.filter { $0.key.libraryRootPath == root }.map(\.value.task)
        OtosLog.mediaIO.noticeOperation("preview.quiesce", phase: "start", fields: [
            "rootPath": root.rawValue,
            "running": "\(running.count)",
        ])
        // The decodes this root had in flight, each to its end: a decode that started is
        // never cut short, and none can start here meanwhile.
        for task in running {
            _ = await task.value
        }
        OtosLog.mediaIO.noticeOperation("preview.quiesce", phase: "finish", fields: ["rootPath": root.rawValue])
    }

    func resume(under root: LibraryRootPath) {
        quiescedRoots.remove(root)
    }

    private func decode(_ request: Request) async -> Outcome {
        let url = request.id.fileURL
        let signpost = OtosSignpost.mediaIO.beginInterval("PreviewDecode")
        let start = ContinuousClock.now
        defer {
            OtosSignpost.mediaIO.endInterval("PreviewDecode", signpost)
        }

        // A still's stored preview serves every request short of full resolution, without
        // touching the original — cloud-only or not (ADR 0035). The original's size comes
        // from catalog metadata, because reading its header would download it. A preview
        // that is missing or unreadable falls through to the original below.
        if request.targetLongEdge != Self.fullResolution, request.detail?.bestKind != .video,
           let previewPath = request.detail?.previewPath, let directory = derivedImageDirectory
        {
            let stored = await Task.detached(priority: .medium) {
                ThumbnailStore.load(previewPath, in: directory)
            }.value
            if let stored {
                OtosLog.mediaIO.notice(
                    """
                    op=preview.decode phase=ok id=\(request.id.relativePath.rawValue, privacy: .public) \
                    decodeMs=\(DiagnosticsTiming.milliseconds(since: start), privacy: .public) source=storedPreview \
                    edge=\(request.targetLongEdge, privacy: .public) decoded=\(max(stored.width, stored.height), privacy: .public)
                    """
                )
                return .image(stored, nativePixelSize: request.detail?.nativePixelSize)
            }
            OtosLog.mediaIO.notice(
                "op=preview.decode phase=storedPreviewUnreadable id=\(request.id.relativePath.rawValue, privacy: .public)"
            )
        }

        let isVideo = request.detail?.bestKind == .video
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
        let readiness = await materializationRequester.ensureLocal(
            MaterializationCoordinator.Request(
                id: request.id,
                sourceSize: request.detail?.byteSize,
                isVideo: isVideo,
                priority: .interactive
            )
        )
        guard readiness.isLocal else {
            OtosLog.mediaIO.notice(
                """
                op=preview.decode phase=unavailable id=\(request.id.relativePath.rawValue, privacy: .public) \
                readiness=\(String(describing: readiness), privacy: .public)
                """
            )
            return .unavailable
        }

        // Re-check immediately before the byte read (ADR 0008).
        guard status(url) == .materialized else {
            return .unavailable
        }

        // Decode in a `Task.detached` (off this actor) so two panes can decode concurrently and bookkeeping
        // stays responsive. Dataless/materialize gates above already ran in order.
        // ImageIO thumbnail creation waits on Default-QoS internal workers; matching
        // that QoS avoids the Thread Performance Checker priority-inversion hang risk
        // that fires when this path runs at .userInitiated.
        let target = request.targetLongEdge
        let recipe = request.detail?.editRecipe ?? .neutral
        let decoded: (CGImage, String, CGSize?)? = await Task.detached(priority: .medium) { () -> (
            CGImage,
            String,
            CGSize?
        )? in
            if isVideo {
                return await Self.decodeVideoPoster(url: url, targetLongEdge: target)
            }
            if ImageRenderer.isRAW(url) || !recipe.isNeutral {
                return await Self.render(url: url, targetLongEdge: target, recipe: recipe)
            }
            return Self.decodeImage(url: url, targetLongEdge: target)
        }.value

        let decodeMs = DiagnosticsTiming.milliseconds(since: start)
        guard let (image, source, nativePixelSize) = decoded else {
            OtosLog.mediaIO.notice(
                """
                op=preview.decode phase=fail id=\(request.id.relativePath.rawValue, privacy: .public) \
                decodeMs=\(decodeMs, privacy: .public)
                """
            )
            return .unavailable
        }
        OtosLog.mediaIO.notice(
            """
            op=preview.decode phase=ok id=\(request.id.relativePath.rawValue, privacy: .public) \
            decodeMs=\(decodeMs, privacy: .public) source=\(source, privacy: .public) \
            edge=\(request.targetLongEdge, privacy: .public) \
            decoded=\(max(image.width, image.height), privacy: .public)
            """
        )
        return .image(image, nativePixelSize: nativePixelSize)
    }

    /// A RAW, or an edited still, is rendered by the interactive renderer with its saved
    /// recipe — a RAW never shown as the camera's embedded JPEG, so the loupe matches the
    /// grid (ADR 0035, ADR 0036).
    private nonisolated static func render(
        url: URL,
        targetLongEdge: Int,
        recipe: EditRecipe
    ) async -> (CGImage, String, CGSize?)? {
        let longEdge = targetLongEdge == fullResolution ? nil : targetLongEdge
        guard let rendered = try? await ImageRenderer.interactive.render(url, longEdge: longEdge, recipe: recipe) else {
            return nil
        }
        return (rendered.image, "render-\(rendered.decoder.rawValue)", rendered.nativePixelSize)
    }

    private nonisolated static func decodeImage(url: URL, targetLongEdge: Int) -> (CGImage, String, CGSize?)? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        let nativePixelSize = Self.nativePixelSize(of: source)
        let nativeLongEdge = nativePixelSize.map { Int(max($0.width, $0.height)) }
        // A full-resolution request is the source's own long edge; a smaller image
        // never upsamples.
        let target: Int = if targetLongEdge == fullResolution {
            nativeLongEdge ?? 16384
        } else {
            targetLongEdge
        }
        // Prefer an embedded thumbnail when it is already large enough (common for RAW);
        // for the full tier only an embedded image at native size qualifies.
        let embeddedFloor = targetLongEdge == fullResolution ? (nativeLongEdge ?? Int.max) : min(target, 1024)
        if let embedded = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
            ] as CFDictionary
        ), max(embedded.width, embedded.height) >= embeddedFloor {
            return (embedded, "embedded", nativePixelSize)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
            ] as CFDictionary
        ) else {
            return nil
        }
        return (image, "imageio", nativePixelSize)
    }

    /// Oriented pixel size from the source's properties — a header read, no decode.
    /// EXIF orientations 5–8 swap width and height.
    private nonisolated static func nativePixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else {
            return nil
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let swapped = orientation >= 5
        return swapped ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    private nonisolated static func decodeVideoPoster(
        url: URL,
        targetLongEdge: Int
    ) async -> (CGImage, String, CGSize?)? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: targetLongEdge, height: targetLongEdge),
            scale: 1,
            representationTypes: [.thumbnail, .lowQualityThumbnail]
        )
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(
                for: request
            )
            return (representation.cgImage, "quicklook", nil)
        } catch {
            return nil
        }
    }

    private func insert(
        _ image: CGImage,
        for id: MediaAssetID,
        longEdge: Int,
        nativePixelSize: CGSize?,
        revision: Int64
    ) {
        // A smaller decode that finishes after a larger one must not replace it — unless
        // it shows a newer edit.
        if let existing = cache[id], existing.longEdge >= longEdge, existing.revision >= revision {
            touch(id)
            return
        }
        cache[id] = CacheEntry(image: image, longEdge: longEdge, nativePixelSize: nativePixelSize, revision: revision)
        touch(id)
        while cacheOrder.count > Self.retainedPhotos {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    private func touch(_ id: MediaAssetID) {
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
    }
}
