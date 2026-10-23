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
}

/// Preview image loader guide
///
/// The loupe/compare analog of `EnrichmentCoordinator`'s byte-read role, and the app's
/// only full-size decode path (ADR 0016). Callers ask for a preview at a target long edge;
/// this actor gates on `FileMaterialization.status` immediately before every byte read,
/// deliberately materializes dataless originals through the non-blocking helper when the
/// user has opened loupe/compare, and returns a downsampled `CGImage` or `.unavailable`.
///
/// Per-id in-flight work is coalesced. A small LRU holds recent decodes; a cache hit
/// requires `entry.longEdge >= request.targetLongEdge` so a screen-size change re-decodes
/// instead of upscaling. Stale results are rejected by the ViewModel's expected-asset
/// identity check — this actor returns whatever it decoded.
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

    private struct CacheEntry {
        let image: CGImage
        let byteCost: Int
        let longEdge: Int
        let nativePixelSize: CGSize?
    }

    private let materializationRequester: any MaterializationRequesting
    private let status: @Sendable (URL) -> FileMaterializationStatus
    private let maxCacheBytes: Int
    private var cache: [MediaAssetID: CacheEntry] = [:]
    private var cacheOrder: [MediaAssetID] = []
    private var cacheBytes = 0
    /// One decode per asset in flight, remembered with the size it was asked for. A second
    /// request shares it only when that decode is at least as large as the one it needs;
    /// otherwise it would be handed a smaller image than it asked for.
    private struct InFlightDecode {
        let longEdge: Int
        let task: Task<Outcome, Never>
    }

    private var inFlight: [MediaAssetID: InFlightDecode] = [:]

    init(
        maxCacheBytes: Int = 256 * 1024 * 1024,
        status: @escaping @Sendable (URL) -> FileMaterializationStatus = FileMaterialization.status(of:),
        materializationRequester: any MaterializationRequesting
    ) {
        self.maxCacheBytes = maxCacheBytes
        self.status = status
        self.materializationRequester = materializationRequester
    }

    /// Decodes (or materializes then decodes) a preview for `request.id`. Cached hits
    /// return immediately when the stored long edge is large enough. Concurrent requests
    /// for the same id share one in-flight task.
    func preview(for request: Request) async -> Outcome {
        if let cached = cache[request.id], cached.longEdge >= request.targetLongEdge {
            touch(request.id)
            return .image(cached.image, nativePixelSize: cached.nativePixelSize)
        }
        if let existing = inFlight[request.id], existing.longEdge >= request.targetLongEdge {
            return await existing.task.value
        }
        let task = Task(priority: .userInitiated) {
            await self.decode(request)
        }
        // A larger request replaces a smaller decode's entry; the smaller one finishes for
        // its own caller, and each caller removes only the entry it owns.
        inFlight[request.id] = InFlightDecode(longEdge: request.targetLongEdge, task: task)
        let outcome = await task.value
        if inFlight[request.id]?.longEdge == request.targetLongEdge {
            inFlight[request.id] = nil
        }
        if case let .image(image, nativePixelSize) = outcome {
            insert(image, for: request.id, longEdge: request.targetLongEdge, nativePixelSize: nativePixelSize)
        }
        return outcome
    }

    private func decode(_ request: Request) async -> Outcome {
        let url = request.id.fileURL
        let signpost = OtosSignpost.mediaIO.beginInterval("PreviewDecode")
        let start = Date()
        defer {
            OtosSignpost.mediaIO.endInterval("PreviewDecode", signpost)
        }

        switch status(url) {
        case .dataless:
            OtosLog.mediaIO.notice(
                "op=preview.decode phase=materialize id=\(request.id.relativePath.rawValue, privacy: .public)"
            )
            let isVideo = request.detail?.bestKind == .video
                || UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
            let result = await materializationRequester.materialize(
                MaterializationCoordinator.Request(
                    id: request.id,
                    sourceSize: request.detail?.enrichedSourceSize,
                    isVideo: isVideo,
                    priority: .interactive
                )
            )
            guard result.isMaterialized else {
                OtosLog.mediaIO.notice(
                    """
                    op=preview.decode phase=notMaterialized id=\(request.id.relativePath.rawValue, privacy: .public) \
                    outcome=\(String(describing: result.outcome), privacy: .public)
                    """
                )
                return .unavailable
            }
        case .unknown:
            OtosLog.mediaIO.notice(
                "op=preview.decode phase=unavailable id=\(request.id.relativePath.rawValue, privacy: .public)"
            )
            return .unavailable
        case .materialized:
            break
        }

        // Re-check immediately before the byte read (ADR 0008).
        guard status(url) == .materialized else {
            return .unavailable
        }

        let isMovie = request.detail?.bestKind == .video
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true

        // Decode in a `Task.detached` (off this actor) so two panes can decode concurrently and bookkeeping
        // stays responsive. Dataless/materialize gates above already ran in order.
        // ImageIO thumbnail creation waits on Default-QoS internal workers; matching
        // that QoS avoids the Thread Performance Checker priority-inversion hang risk
        // that fires when this path runs at .userInitiated.
        let target = request.targetLongEdge
        let decoded: (CGImage, String, CGSize?)? = await Task.detached(priority: .medium) { () -> (
            CGImage,
            String,
            CGSize?
        )? in
            if isMovie {
                return await Self.decodeVideoPoster(url: url, targetLongEdge: target)
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

    private func insert(_ image: CGImage, for id: MediaAssetID, longEdge: Int, nativePixelSize: CGSize?) {
        // A smaller decode that finishes after a larger one must not replace it.
        if let existing = cache[id], existing.longEdge >= longEdge {
            touch(id)
            return
        }
        let cost = image.height * image.bytesPerRow
        if let existing = cache[id] {
            cacheBytes -= existing.byteCost
        }
        cache[id] = CacheEntry(image: image, byteCost: cost, longEdge: longEdge, nativePixelSize: nativePixelSize)
        cacheBytes += cost
        touch(id)
        evictIfNeeded(keeping: [id])
    }

    private func touch(_ id: MediaAssetID) {
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
    }

    private func evictIfNeeded(keeping pinned: Set<MediaAssetID>) {
        while cacheBytes > maxCacheBytes, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            if pinned.contains(oldest) {
                cacheOrder.append(oldest)
                // Avoid infinite loop when everything pinned exceeds budget.
                if cacheOrder.allSatisfy(pinned.contains) {
                    break
                }
                continue
            }
            if let entry = cache.removeValue(forKey: oldest) {
                cacheBytes -= entry.byteCost
            }
        }
    }
}
