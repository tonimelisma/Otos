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
/// read again. A write lands only while the row still has the preview that was read. Only a
/// preview that decoded and held no face is stamped with no faces. A preview that could not
/// be read or decoded, or whose analysis failed, writes nothing: the still stays owed and is
/// offered again after `retryPacing`, or at once when its preview changes
/// (`PreviewFaceRetries`). When the model cannot be loaded no still can be read, so the drain
/// stops and reading resumes after the same pacing, not at the next catalog change.
///
/// One loop, woken by a doorbell (ADR 0032 rule 3) that the Store's change notifications and
/// the retry wake ring; each wake drains every stale row in pages. The previews are decoded
/// and analysed off this actor, by `FaceAnalyzer` on its own queue. The forwarder and the loop
/// hold this actor weakly and end with it; the wake holds only the doorbell.
actor PreviewFaceReader {
    private let store: CatalogStore
    private let thumbnailDirectory: URL?
    private let analyzeFaces: FaceAnalysisReader
    private let pageSize: Int
    private var retries: PreviewFaceRetries
    private var doorbell: AsyncStream<Void>.Continuation?
    private var loop: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?
    /// Rings the doorbell when the earliest retry comes due; replaced when that changes.
    private var wake: (task: Task<Void, Never>, at: ContinuousClock.Instant)?
    /// Drains run, to their end or stopped: what a test waits on, and logged with each read.
    private(set) var drains = 0

    /// How long a still whose faces could not be read, or every still while the model cannot
    /// be loaded, waits before it is read again.
    static let retryPacing: Duration = .seconds(900)

    init(
        store: CatalogStore,
        thumbnailDirectory: URL?,
        analyzeFaces: @escaping FaceAnalysisReader,
        pageSize: Int = 32,
        retryPacing: Duration = PreviewFaceReader.retryPacing
    ) {
        self.store = store
        self.thumbnailDirectory = thumbnailDirectory
        self.analyzeFaces = analyzeFaces
        self.pageSize = pageSize
        retries = PreviewFaceRetries(pacing: retryPacing)
    }

    /// Starts the loop and the forwarder. Both are made and stored here with no suspension
    /// between the check and the store (ADR 0032 rule 1), so a second call finds them. The
    /// forwarder rings once it holds the change stream, so a change made before it subscribed
    /// is read by the drain that ring starts.
    func start() {
        guard loop == nil else { return }
        let (bell, ring) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        doorbell = ring
        forwarder = Task { [weak self, store] in
            let changes = await store.changeNotifications()
            ring.yield()
            for await change in changes {
                guard self != nil else { break }
                if change == .catalogChanged || change == .assetsDetailChanged {
                    ring.yield()
                }
            }
            ring.finish()
        }
        loop = Task { [weak self] in
            for await _ in bell {
                guard let self else { return }
                await drain()
            }
        }
    }

    /// Ends the loop now — a test's teardown; in the app, the loops end with the actor.
    func shutdown() {
        forwarder?.cancel()
        loop?.cancel()
        wake?.task.cancel()
        forwarder = nil
        loop = nil
        wake = nil
        doorbell = nil
    }

    /// Reads every row owed faces once, a page at a time in catalog order, each page after the
    /// last row of the one before. A row whose read failed is left owed, paced and passed over,
    /// so it never holds back the rows after it. A model that cannot be loaded stops the drain.
    private func drain() async {
        defer { drains += 1 }
        let now = ContinuousClock.now
        guard retries.admitsModel(at: now) else {
            armWake(after: now)
            return
        }
        var stored = 0
        var failed = 0
        var cursor: PreviewFaceCursor?
        var offered: Set<MediaAssetID> = []
        var reachedEnd = false
        var modelUnavailable = false
        while !Task.isCancelled, !modelUnavailable {
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
            for candidate in page.candidates where !modelUnavailable {
                offered.insert(candidate.id)
                guard retries.admits(candidate, at: now) else { continue }
                switch await read(candidate) {
                case let .faces(faces):
                    retries.read(candidate)
                    results.append(PreviewFaceResult(candidate: candidate, faces: faces))
                case .failed:
                    retries.failed(candidate, at: now)
                    failed += 1
                case .modelUnavailable:
                    retries.modelFailed(at: now)
                    modelUnavailable = true
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
            guard let next = page.next else {
                reachedEnd = true
                break
            }
            cursor = next
        }
        // A still no longer owed faces has nothing to retry.
        if reachedEnd, !modelUnavailable {
            retries.keep(only: offered)
        }
        armWake(after: now)
        if stored > 0 || failed > 0 || modelUnavailable {
            OtosLog.metadata.noticeOperation("face.preview", phase: "read", fields: [
                "count": "\(stored)", "failed": "\(failed)", "modelUnavailable": "\(modelUnavailable)",
                "paced": "\(retries.stills.count)", "drain": "\(drains)",
            ])
        }
    }

    /// Rings the doorbell when the earliest retry comes due, if one waits.
    private func armWake(after now: ContinuousClock.Instant) {
        guard let due = retries.nextWake(after: now) else {
            wake?.task.cancel()
            wake = nil
            return
        }
        guard wake?.at != due else { return }
        wake?.task.cancel()
        let ring = doorbell
        wake = (Task {
            do {
                // time: backoff — a preview that could not be read, or a model that could not
                // be loaded, reports nothing when it would succeed.
                try await Task.sleep(until: due, clock: .continuous)
            } catch {
                return
            }
            ring?.yield()
        }, due)
    }

    /// What reading one candidate came to.
    enum Reading {
        /// The faces, placed on the upright photo; none when the preview decoded and held none.
        case faces(EnrichedFaces)
        /// This preview could not be read, decoded or analysed: nothing is known of its faces.
        case failed
        /// The model could not be loaded, so no preview can be read.
        case modelUnavailable
    }

    /// The faces of one candidate's preview. A preview that cannot be read or decoded, or
    /// whose analysis failed, is `failed`: nothing is stamped, since a stamp would say the
    /// still holds no face (ADR 0032 rule 4).
    private func read(_ candidate: PreviewFaceCandidate) async -> Reading {
        guard let thumbnailDirectory else { return .failed }
        let url = thumbnailDirectory.appending(path: candidate.previewPath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            OtosLog.metadata.errorOperation("face.preview", phase: "previewUnreadable", fields: [
                "relativePath": candidate.id.relativePath.rawValue, "preview": candidate.previewPath,
            ])
            return .failed
        }
        guard let image = await Self.decode(url) else {
            OtosLog.metadata.errorOperation("face.preview", phase: "previewUndecodable", fields: [
                "relativePath": candidate.id.relativePath.rawValue, "preview": candidate.previewPath,
            ])
            return .failed
        }
        do {
            let analysis = try await analyzeFaces(image)
            let edited = CGSize(width: image.width, height: image.height)
            return .faces(EnrichedFaces(
                faces: analysis.faces.map { Self.upright($0, readFrom: edited, recipe: candidate.recipe) },
                analysisRevision: FaceAnalyzer.revision
            ))
        } catch let FaceAnalysisError.modelUnavailable(description) {
            OtosLog.metadata.errorOperation("face.preview", phase: "modelUnavailable", fields: [
                "relativePath": candidate.id.relativePath.rawValue, "error": description,
            ])
            return .modelUnavailable
        } catch {
            OtosLog.metadata.errorOperation("face.preview", phase: "analysisFailed", fields: [
                "relativePath": candidate.id.relativePath.rawValue, "error": String(describing: error),
            ])
            return .failed
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

    /// The stored preview, decoded whole and turned upright by any orientation it carries; nil
    /// when it could not be, whatever the reason: nothing is then known of its faces.
    @concurrent
    private static func decode(_ url: URL) async -> CGImage? {
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

/// When a still whose faces could not be read is offered again, and when reading resumes after
/// the model could not be loaded (ADR 0047). A value with synchronous transitions (ADR 0032
/// rule 1): every instant comes in as an argument, so each wait is tested by passing the
/// instant it covers rather than by waiting for it.
nonisolated struct PreviewFaceRetries: Sendable {
    /// A still whose read failed, and the preview it failed on: a new preview is read at once.
    struct Entry: Sendable, Equatable {
        let candidate: PreviewFaceCandidate
        let notBefore: ContinuousClock.Instant
    }

    let pacing: Duration
    private(set) var stills: [MediaAssetID: Entry] = [:]
    private(set) var modelNotBefore: ContinuousClock.Instant?

    init(pacing: Duration) {
        self.pacing = pacing
    }

    /// Whether any still may be read at `now`: not while the model waits out its pacing.
    func admitsModel(at now: ContinuousClock.Instant) -> Bool {
        modelNotBefore.map { $0 <= now } ?? true
    }

    /// Whether `candidate` may be read at `now`: unless its read failed on this same preview
    /// and its pacing has not passed.
    func admits(_ candidate: PreviewFaceCandidate, at now: ContinuousClock.Instant) -> Bool {
        guard let entry = stills[candidate.id], entry.candidate == candidate else { return true }
        return entry.notBefore <= now
    }

    mutating func failed(_ candidate: PreviewFaceCandidate, at now: ContinuousClock.Instant) {
        stills[candidate.id] = Entry(candidate: candidate, notBefore: now.advanced(by: pacing))
    }

    /// A read that came to faces: neither the still nor the model waits any longer.
    mutating func read(_ candidate: PreviewFaceCandidate) {
        stills[candidate.id] = nil
        modelNotBefore = nil
    }

    mutating func modelFailed(at now: ContinuousClock.Instant) {
        modelNotBefore = now.advanced(by: pacing)
    }

    /// Keeps only the stills still owed faces.
    mutating func keep(only owed: Set<MediaAssetID>) {
        stills = stills.filter { owed.contains($0.key) }
    }

    /// The earliest retry still ahead of `now`, or nil when nothing waits.
    func nextWake(after now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        ([modelNotBefore].compactMap(\.self) + stills.values.map(\.notBefore)).filter { $0 > now }.min()
    }
}
