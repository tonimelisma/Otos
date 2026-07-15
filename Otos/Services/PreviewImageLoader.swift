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
/// user has opened loupe/compare, and returns a downsampled `CGImage` (or `.downloading` /
/// `.unavailable`).
///
/// Per-id in-flight work is coalesced. A small LRU holds recent decodes; a cache hit
/// requires `entry.longEdge >= request.targetLongEdge` so a screen-size change re-decodes
/// instead of upscaling. Stale results are rejected by the ViewModel's expected-asset
/// identity check — this actor returns whatever it decoded.
actor PreviewImageLoader: PreviewLoading {
    enum Outcome {
        case image(CGImage)
        case downloading
        case unavailable
    }

    struct Request {
        let id: MediaAssetID
        let detail: MediaTileDetail?
        let targetLongEdge: Int
    }

    private struct CacheEntry {
        let image: CGImage
        let byteCost: Int
        let longEdge: Int
    }

    private let materializationRequester: any MaterializationRequesting
    private let status: @Sendable (URL) -> FileMaterializationStatus
    private let maxCacheBytes: Int
    private var cache: [MediaAssetID: CacheEntry] = [:]
    private var cacheOrder: [MediaAssetID] = []
    private var cacheBytes = 0
    private var inFlight: [MediaAssetID: Task<Outcome, Never>] = [:]

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
            return .image(cached.image)
        }
        if let existing = inFlight[request.id] {
            return await existing.value
        }
        let task = Task(priority: .userInitiated) {
            await self.decode(request)
        }
        inFlight[request.id] = task
        let outcome = await task.value
        inFlight[request.id] = nil
        if case let .image(image) = outcome {
            insert(image, for: request.id, longEdge: request.targetLongEdge)
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
                    op=preview.decode phase=downloading id=\(request.id.relativePath.rawValue, privacy: .public) \
                    outcome=\(String(describing: result.outcome), privacy: .public)
                    """
                )
                return .downloading
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
            return .downloading
        }

        let isMovie = request.detail?.bestKind == .video
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true

        // Decode off the actor so two panes can decode concurrently and bookkeeping
        // stays responsive. Dataless/materialize gates above already ran in order.
        let target = request.targetLongEdge
        let decoded: (CGImage, String)? = await Task.detached(priority: .userInitiated) {
            if isMovie {
                await Self.decodeVideoPoster(url: url, targetLongEdge: target)
            } else {
                Self.decodeImage(url: url, targetLongEdge: target)
            }
        }.value

        let decodeMs = DiagnosticsTiming.milliseconds(since: start)
        guard let (image, source) = decoded else {
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
            edge=\(request.targetLongEdge, privacy: .public)
            """
        )
        return .image(image)
    }

    private nonisolated static func decodeImage(url: URL, targetLongEdge: Int) -> (CGImage, String)? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        // Prefer an embedded thumbnail when it is already large enough (common for RAW).
        if let embedded = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: targetLongEdge,
            ] as CFDictionary
        ), max(embedded.width, embedded.height) >= min(targetLongEdge, 1024) {
            return (embedded, "embedded")
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: targetLongEdge,
            ] as CFDictionary
        ) else {
            return nil
        }
        return (image, "imageio")
    }

    private nonisolated static func decodeVideoPoster(
        url: URL,
        targetLongEdge: Int
    ) async -> (CGImage, String)? {
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
            return (representation.cgImage, "quicklook")
        } catch {
            return nil
        }
    }

    private func insert(_ image: CGImage, for id: MediaAssetID, longEdge: Int) {
        let cost = image.height * image.bytesPerRow
        if let existing = cache[id] {
            cacheBytes -= existing.byteCost
        }
        cache[id] = CacheEntry(image: image, byteCost: cost, longEdge: longEdge)
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
