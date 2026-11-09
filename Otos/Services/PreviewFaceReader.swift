import CoreGraphics
import Foundation
import ImageIO

/// Preview face reader guide (ADR 0047)
///
/// The one producer of an Immich account's faces: each still is read from its **stored
/// preview** in Application Support, the image Immich made and Otos downloaded on sync
/// (ADR 0046 §7). It never opens an original, so it never downloads one. Measured on the
/// owner's labels, a preview smaller than Immich's finds 93% of faces and matches none to the
/// wrong person (`docs/research/2026-11-07-face-recognition-models.md`, section 7).
///
/// The faces are stamped with the source stamp the preview was made for, so a newer Immich
/// version, with its new preview, is read again; a write lands only while the row still has
/// the preview that was read. A preview that does not decode is stamped with no faces, so it
/// is not offered again until a new one arrives; a failed analysis writes nothing and waits
/// for the next ring.
///
/// One loop, woken by a doorbell (ADR 0032 rule 3) that the Store's change notifications
/// ring; each wake drains every stale row in pages. The previews are decoded and analysed off
/// this actor, by the shared `FaceAnalyzer` on its own queue. The forwarder and the loop hold
/// this actor weakly and end with it.
actor PreviewFaceReader {
    private let store: CatalogStore
    private let thumbnailDirectory: URL?
    private let analyzeFaces: MediaEnricher.FaceAnalysisReader
    private let pageSize: Int
    private var loop: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?

    init(
        store: CatalogStore,
        thumbnailDirectory: URL?,
        analyzeFaces: @escaping MediaEnricher.FaceAnalysisReader,
        pageSize: Int = 32
    ) {
        self.store = store
        self.thumbnailDirectory = thumbnailDirectory
        self.analyzeFaces = analyzeFaces
        self.pageSize = pageSize
    }

    func start() async {
        guard loop == nil else { return }
        let (doorbell, ring) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let changes = await store.changeNotifications()
        ring.yield()
        forwarder = Task { [weak self] in
            for await change in changes {
                guard self != nil else { break }
                if change == .catalogChanged || change == .assetsDetailChanged {
                    ring.yield()
                }
            }
            ring.finish()
        }
        loop = Task { [weak self] in
            for await _ in doorbell {
                guard let self else { return }
                await drain()
            }
        }
    }

    /// Ends the loop now — a test's teardown; in the app, the loops end with the actor.
    func shutdown() {
        forwarder?.cancel()
        loop?.cancel()
        forwarder = nil
        loop = nil
    }

    /// Reads every stale row, a page at a time, until none is left or a page wrote nothing
    /// (every row failed or changed meanwhile, and waits for the next ring).
    private func drain() async {
        var stored = 0
        while !Task.isCancelled {
            let page: [PreviewFaceCandidate]
            do {
                page = try await store.previewFaceCandidates(limit: pageSize)
            } catch {
                OtosLog.metadata.errorOperation("face.preview", phase: "readFailed", fields: [
                    "error": String(describing: error),
                ])
                return
            }
            guard !page.isEmpty else { break }
            var results: [PreviewFaceResult] = []
            for candidate in page {
                if let faces = await read(candidate) {
                    results.append(PreviewFaceResult(candidate: candidate, faces: faces))
                }
            }
            let written: Int
            do {
                written = try await store.applyPreviewFaces(results)
            } catch {
                OtosLog.metadata.errorOperation("face.preview", phase: "writeFailed", fields: [
                    "count": "\(results.count)", "error": String(describing: error),
                ])
                return
            }
            stored += written
            if written == 0 {
                break
            }
        }
        if stored > 0 {
            OtosLog.metadata.noticeOperation("face.preview", phase: "read", fields: ["count": "\(stored)"])
        }
    }

    /// The faces of one candidate's preview; no faces when it does not decode; nil when the
    /// analysis failed, so nothing is stamped.
    private func read(_ candidate: PreviewFaceCandidate) async -> EnrichedFaces? {
        guard let thumbnailDirectory else { return nil }
        guard let image = await Self.decode(candidate, thumbnailDirectory: thumbnailDirectory) else {
            return .noneFound
        }
        do {
            let analysis = try await analyzeFaces(image)
            return EnrichedFaces(faces: analysis.faces, analysisRevision: FaceAnalyzer.revision)
        } catch {
            OtosLog.metadata.errorOperation("face.preview", phase: "analysisFailed", fields: [
                "relativePath": candidate.id.relativePath.rawValue, "error": String(describing: error),
            ])
            return nil
        }
    }

    /// The stored preview, decoded whole and turned upright by any orientation it carries.
    @concurrent
    private static func decode(_ candidate: PreviewFaceCandidate, thumbnailDirectory: URL) async -> CGImage? {
        let url = thumbnailDirectory.appending(path: candidate.previewPath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ] as CFDictionary)
    }
}
