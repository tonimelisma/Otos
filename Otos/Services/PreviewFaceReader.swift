import CoreGraphics
import Foundation
import ImageIO

/// Preview face reader guide (ADR 0047)
///
/// The one producer of faces: every still in a library or an Immich account is read for its
/// faces from its **stored preview** in Application Support — Otos's 2560 px rendering
/// (ADR 0035), or until there is one, the source's own preview (an Immich preview, ADR 0046
/// §7). It never opens an original, so it never downloads one. Measured on the owner's
/// labels, faces read from the preview make the same identity decisions as faces read from
/// the original at full resolution
/// (`docs/research/2026-11-12-faces-from-the-preview.md`).
///
/// A preview shows the photo's saved edit, and a face is stored on the upright photo, so each
/// face read from it is carried back through the edit's geometry (`EditGeometry`). A preview
/// whose edit is no longer the one stored waits for its new rendering.
///
/// The faces are stamped with the source stamp the preview was made from, so a new version
/// of the file, with its new preview, is read again; an edit is not a new source and is not
/// read again. A write lands only while the row still has the preview that was read. A
/// preview that does not decode is stamped with no faces, so it is not offered again until a
/// new one arrives; a failed analysis writes nothing and waits for the next ring.
///
/// One loop, woken by a doorbell (ADR 0032 rule 3) that the Store's change notifications
/// ring; each wake drains every stale row in pages. The previews are decoded and analysed off
/// this actor, by `FaceAnalyzer` on its own queue. The forwarder and the loop hold this actor
/// weakly and end with it.
actor PreviewFaceReader {
    private let store: CatalogStore
    private let thumbnailDirectory: URL?
    private let analyzeFaces: FaceAnalysisReader
    private let pageSize: Int
    private var loop: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?

    init(
        store: CatalogStore,
        thumbnailDirectory: URL?,
        analyzeFaces: @escaping FaceAnalysisReader,
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

    /// Reads every row owed faces once, a page at a time in catalog order, each page after the
    /// last row of the one before. A row whose read failed is left owed and passed over, so it
    /// is tried again at the next ring and never holds back the rows after it.
    private func drain() async {
        var stored = 0
        var cursor: PreviewFaceCursor?
        while !Task.isCancelled {
            let page: PreviewFacePage
            do {
                page = try await store.previewFaceCandidates(after: cursor, limit: pageSize)
            } catch {
                OtosLog.metadata.errorOperation("face.preview", phase: "readFailed", fields: [
                    "error": String(describing: error),
                ])
                return
            }
            var results: [PreviewFaceResult] = []
            for candidate in page.candidates {
                if let faces = await read(candidate) {
                    results.append(PreviewFaceResult(candidate: candidate, faces: faces))
                }
            }
            do {
                stored += try await store.applyPreviewFaces(results)
            } catch {
                OtosLog.metadata.errorOperation("face.preview", phase: "writeFailed", fields: [
                    "count": "\(results.count)", "error": String(describing: error),
                ])
                return
            }
            guard let next = page.next else { break }
            cursor = next
        }
        if stored > 0 {
            OtosLog.metadata.noticeOperation("face.preview", phase: "read", fields: ["count": "\(stored)"])
        }
    }

    /// The faces of one candidate's preview, placed on the upright photo; no faces when it
    /// does not decode; nil when the analysis failed, so nothing is stamped.
    private func read(_ candidate: PreviewFaceCandidate) async -> EnrichedFaces? {
        guard let thumbnailDirectory else { return nil }
        guard let image = await Self.decode(candidate, thumbnailDirectory: thumbnailDirectory) else {
            return .noneFound
        }
        do {
            let analysis = try await analyzeFaces(image)
            let edited = CGSize(width: image.width, height: image.height)
            return EnrichedFaces(
                faces: analysis.faces.map { Self.upright($0, readFrom: edited, recipe: candidate.recipe) },
                analysisRevision: FaceAnalyzer.revision
            )
        } catch {
            OtosLog.metadata.errorOperation("face.preview", phase: "analysisFailed", fields: [
                "relativePath": candidate.id.relativePath.rawValue, "error": String(describing: error),
            ])
            return nil
        }
    }

    /// `face`, read from a preview of `edited` size showing `recipe`, as it lies on the
    /// upright photo: its five points carried back through the edit's geometry, and its box
    /// the bounds of its corners carried back, kept inside the photo. A preview with no
    /// geometry in its edit is the upright photo.
    static func upright(_ face: DetectedFace, readFrom edited: CGSize, recipe: EditRecipe) -> DetectedFace {
        guard recipe.hasGeometry else { return face }
        let geometry = EditGeometry(recipe: recipe, developedSize: EditGeometry.developedSize(ofEdited: edited, recipe: recipe))
        let corners = [
            CGPoint(x: face.box.minX, y: face.box.minY), CGPoint(x: face.box.maxX, y: face.box.minY),
            CGPoint(x: face.box.minX, y: face.box.maxY), CGPoint(x: face.box.maxX, y: face.box.maxY),
        ].map(geometry.developedFraction(atEditedFraction:))
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return DetectedFace(
            box: box,
            landmarks: FaceAlignment.Landmarks(
                leftEye: geometry.developedFraction(atEditedFraction: face.landmarks.leftEye),
                rightEye: geometry.developedFraction(atEditedFraction: face.landmarks.rightEye),
                nose: geometry.developedFraction(atEditedFraction: face.landmarks.nose),
                leftMouth: geometry.developedFraction(atEditedFraction: face.landmarks.leftMouth),
                rightMouth: geometry.developedFraction(atEditedFraction: face.landmarks.rightMouth)
            ),
            quality: face.quality,
            embedding: face.embedding
        )
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
