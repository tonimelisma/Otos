import CoreGraphics
import Foundation
import ImageIO
import OSLog
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Preview image loader guide
///
/// The loupe/compare analog of `EnrichmentCoordinator`'s byte-read role, and the app's
/// only full-size decode path (ADR 0016). Callers ask for a preview at a target long edge;
/// this actor gates on `FileMaterialization.status` immediately before every byte read,
/// deliberately materializes dataless originals through the non-blocking helper when the
/// user has opened loupe/compare, and returns a downsampled `CGImage` (or `.downloading` /
/// `.unavailable`).
///
/// Per-id in-flight work is coalesced. A small pinned LRU holds the focus neighborhood so
/// arrowing back does not re-decode. Stale results are rejected by the caller's generation
/// token — this actor returns whatever it decoded; the ViewModel drops superseded gens.
actor PreviewImageLoader {
    enum Outcome {
        case image(CGImage)
        case downloading
        case unavailable
    }

    struct Request {
        let id: MediaAssetID
        let detail: MediaTileDetail?
        let targetLongEdge: Int
        let generation: UInt64
    }

    private struct CacheEntry {
        let image: CGImage
        let byteCost: Int
    }

    private let materialize: @Sendable (URL) async -> MaterializationResult
    private let status: @Sendable (URL) -> FileMaterializationStatus
    private let maxCacheBytes: Int
    private var cache: [MediaAssetID: CacheEntry] = [:]
    private var cacheOrder: [MediaAssetID] = []
    private var cacheBytes = 0
    private var inFlight: [MediaAssetID: Task<Outcome, Never>] = [:]

    init(
        maxCacheBytes: Int = 256 * 1024 * 1024,
        status: @escaping @Sendable (URL) -> FileMaterializationStatus = FileMaterialization.status(of:),
        materialize: @escaping @Sendable (URL) async -> MaterializationResult = { url in
            await FileMaterialization.materialize(url)
        }
    ) {
        self.maxCacheBytes = maxCacheBytes
        self.status = status
        self.materialize = materialize
    }

    /// Decodes (or materializes then decodes) a preview for `request.id`. Cached hits
    /// return immediately. Concurrent requests for the same id share one in-flight task.
    func preview(for request: Request) async -> (generation: UInt64, outcome: Outcome) {
        if let cached = cache[request.id] {
            touch(request.id)
            return (request.generation, .image(cached.image))
        }
        if let existing = inFlight[request.id] {
            let outcome = await existing.value
            return (request.generation, outcome)
        }
        let task = Task { [request] in
            await self.decode(request)
        }
        inFlight[request.id] = task
        let outcome = await task.value
        inFlight[request.id] = nil
        if case let .image(image) = outcome {
            insert(image, for: request.id)
        }
        return (request.generation, outcome)
    }

    func pin(ids: [MediaAssetID]) {
        let keep = Set(ids)
        cacheOrder.removeAll { !keep.contains($0) && cache[$0] != nil }
        // Recompute bytes after unpinning non-neighbors; then evict if over budget.
        cache = cache.filter { keep.contains($0.key) }
        cacheBytes = cache.values.reduce(0) { $0 + $1.byteCost }
        evictIfNeeded(keeping: keep)
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
            let result = await materialize(url)
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

        let decoded: (CGImage, String)? = if isMovie {
            await decodeVideoPoster(url: url, targetLongEdge: request.targetLongEdge)
        } else {
            decodeImage(url: url, targetLongEdge: request.targetLongEdge)
        }

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

    private func decodeImage(url: URL, targetLongEdge: Int) -> (CGImage, String)? {
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

    private func decodeVideoPoster(url: URL, targetLongEdge: Int) async -> (CGImage, String)? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: targetLongEdge, height: targetLongEdge),
            scale: 1,
            representationTypes: [.thumbnail, .lowQualityThumbnail]
        )
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return (representation.cgImage, "quicklook")
        } catch {
            return nil
        }
    }

    private func insert(_ image: CGImage, for id: MediaAssetID) {
        let cost = image.height * image.bytesPerRow
        if let existing = cache[id] {
            cacheBytes -= existing.byteCost
        }
        cache[id] = CacheEntry(image: image, byteCost: cost)
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
