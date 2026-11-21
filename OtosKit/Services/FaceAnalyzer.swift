import CoreGraphics
import CoreImage
import Foundation
import OSLog
import Vision

/// One face found in a photo and read by the embedding model (ADR 0047).
nonisolated struct DetectedFace: Sendable, Equatable {
    /// The face's box as fractions of the upright photo, top-left origin.
    let box: CGRect
    /// The five alignment points as fractions of the upright photo, top-left origin.
    let landmarks: FaceAlignment.Landmarks
    /// Vision's face capture quality, 0 to 1.
    let quality: Float
    let embedding: FaceEmbedding
}

/// Every face Vision found in one photo, split into those the model read and the reasons the
/// rest were not.
nonisolated struct FaceAnalysis: Sendable, Equatable {
    let faces: [DetectedFace]
    /// Below `FaceAnalyzer.minimumQuality`.
    let rejectedForQuality: Int
    /// No person seen around the face (`FaceAnalyzer.minimumPersonConfidence`): an object
    /// Vision took for a face.
    let rejectedAsNoPerson: Int
    /// Box height × alignment scale outside `FaceAlignment.admittedScaledHeight`: the landmarks
    /// were not one face.
    let rejectedForAlignment: Int
    /// Vision returned no eyes, nose crest or lips to align by.
    let rejectedForLandmarks: Int
}

/// Reads one upright image's faces: a `FaceAnalyzer`'s `analyze` in production, a stub in
/// tests. One is shared by every face reader, so the model loads once. It throws
/// `FaceAnalysisError.modelUnavailable` when no image can be read, and any other error for
/// the one image it was handed.
typealias FaceAnalysisReader = @Sendable (CGImage) async throws -> FaceAnalysis

/// Why no image can be read for faces, as opposed to why one image could not be: a reader
/// that meets it stops reading and tries again after a backoff, rather than failing every
/// image in turn (ADR 0047).
nonisolated enum FaceAnalysisError: Error, Equatable {
    /// The embedding model could not be loaded.
    case modelUnavailable(description: String)
}

/// Face analyzer guide
///
/// Finds the faces in one upright photo and reads each with the embedding model (ADR 0047):
/// Vision's face landmarks and capture quality, the admission rules (among them Vision's image
/// classifier seeing a person around the face), the five-point alignment
/// (`FaceAlignment`), an opaque 112 × 112 crop, and `FaceEmbeddingModel`.
///
/// Every step is blocking CPU work and the model is 66 MB, so the actor runs on its own serial
/// queue rather than the shared pool (ADR 0032 rule 6), loads the model on first use, and the
/// model never leaves it. The caller hands it a still's stored preview, decoded upright
/// (`PreviewFaceReader`), or a video's sampled frame (`VideoFaceReader`); a still's faces are
/// never read from its original.
///
/// The settings are the ones the bake-off measured
/// (`docs/research/2026-11-07-face-recognition-models.md`,
/// `docs/research/2026-11-12-face-person-admission.md`,
/// `docs/research/2026-11-12-faces-from-the-preview.md`), and `revision` names them: the
/// stored preview as the image read, Vision's landmark and quality revision 3, its classifier
/// revision 2, the admission thresholds, the alignment and the model. A change to any of them
/// is a new revision, with a migration that makes the faces it changes stale.
actor FaceAnalyzer {
    /// The analysis these settings produce; stored with every face.
    static let revision = 3

    /// Vision's capture quality below which a face is not read. Read on the 2560 px preview,
    /// Vision scores a face about 0.015 lower than on the original at full resolution, so
    /// 0.28 here admits as many faces as the bake-off's 0.3 did on originals: of the owner's
    /// 5,471 faces read from originals, 123 are not found and 153 others are, against 212 and
    /// 91 at 0.3 (`docs/research/2026-11-12-faces-from-the-preview.md`).
    static let minimumQuality: Float = 0.28

    /// The person-label confidence below which a detection is not read as a face. Vision's
    /// capture quality says how well a face was photographed, not whether it is one: lace, a
    /// bucket, a storefront and drawings passed it and grouped into a person of their own.
    /// Vision's image classifier, shown a square twice the face box, says whether a person is
    /// there. Measured on the owner's catalog
    /// (`docs/research/2026-11-12-face-person-admission.md`): every face the user named reads
    /// 0.28 or more, while 7 of that group's 9 objects read under 0.13.
    static let minimumPersonConfidence: Float = 0.2

    /// The classifier labels that are a person.
    static let personLabels: Set<String> = ["people", "adult", "child", "baby", "teen", "crowd"]

    private let queue = DispatchSerialQueue(label: "net.melisma.Otos.face.analysis", qos: .utility)
    private let bundle: Bundle
    /// Made on first use, on the analysis queue: an analyzer is built on the main actor at
    /// launch, and a Core Image context costs several milliseconds to make.
    private lazy var context = CIContext()
    /// The model, once loaded. A failed load is not kept: it is reported to the reader as
    /// `FaceAnalysisError.modelUnavailable`, which backs off, and the next analysis loads again.
    private var model: FaceEmbeddingModel?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    /// Face analysis by the bundled model: one `FaceAnalyzer`, which loads the model the first
    /// time an image is read.
    static func bundledAnalysis() -> FaceAnalysisReader {
        let analyzer = FaceAnalyzer(bundle: Bundle(for: CatalogWindowViewModel.self))
        return { image in try await analyzer.analyze(image) }
    }

    /// The faces in `image`: a still's upright stored preview or a video's frame. The model is
    /// loaded before any Vision work, so an image is never analysed, and its result never
    /// depends on whether it held a face, while the model is missing.
    func analyze(_ image: CGImage) throws -> FaceAnalysis {
        let model = try embeddingModel()
        let start = ContinuousClock.now
        let size = CGSize(width: image.width, height: image.height)
        let (observations, qualities) = try Self.detect(image)
        let visionElapsed = ContinuousClock.now - start

        let source = CIImage(cgImage: image)
        var faces: [DetectedFace] = []
        var lowQuality = 0, misaligned = 0, noLandmarks = 0, noPerson = 0
        for observation in observations {
            guard let quality = qualities[observation.uuid], quality >= Self.minimumQuality else {
                lowQuality += 1
                continue
            }
            guard let points = Self.alignmentPoints(observation, imageSize: size),
                  let transform = FaceAlignment.similarity(from: points, to: FaceAlignment.template)
            else {
                noLandmarks += 1
                continue
            }
            let boxHeight = observation.boundingBox.height * size.height
            guard FaceAlignment.admits(boxHeight: boxHeight, transform: transform) else {
                misaligned += 1
                continue
            }
            guard let crop = Self.alignedCrop(of: source, transform: transform, context: context) else {
                throw AnalysisError.cropFailed
            }
            guard try Self.personConfidence(around: observation.boundingBox, in: image) >= Self.minimumPersonConfidence else {
                noPerson += 1
                continue
            }
            let embedding = try model.embedding(of: crop)
            faces.append(DetectedFace(
                box: Self.topLeft(observation.boundingBox),
                landmarks: points.map { CGPoint(x: $0.x / size.width, y: 1 - $0.y / size.height) },
                quality: quality,
                embedding: embedding
            ))
        }
        OtosLog.metadata.noticeOperation("face.analyse", phase: "finish", fields: [
            "width": "\(image.width)",
            "height": "\(image.height)",
            "detected": "\(observations.count)",
            "faces": "\(faces.count)",
            "lowQuality": "\(lowQuality)",
            "misaligned": "\(misaligned)",
            "noLandmarks": "\(noLandmarks)",
            "noPerson": "\(noPerson)",
            "visionMs": "\(DiagnosticsTiming.milliseconds(visionElapsed))",
            "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return FaceAnalysis(
            faces: faces,
            rejectedForQuality: lowQuality,
            rejectedAsNoPerson: noPerson,
            rejectedForAlignment: misaligned,
            rejectedForLandmarks: noLandmarks
        )
    }

    /// Vision's faces in `image`, with each face's capture quality by its `uuid`.
    private static func detect(_ image: CGImage) throws -> ([VNFaceObservation], [UUID: Float]) {
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        landmarksRequest.revision = VNDetectFaceLandmarksRequestRevision3
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([landmarksRequest])
        let observations = landmarksRequest.results ?? []
        guard !observations.isEmpty else { return ([], [:]) }
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        qualityRequest.revision = VNDetectFaceCaptureQualityRequestRevision3
        qualityRequest.inputFaceObservations = observations
        try handler.perform([qualityRequest])
        // Paired by uuid, never by position: Vision returns these in its own order, which
        // differed from the input's on 22 of 38 multi-face photos measured.
        var qualities: [UUID: Float] = [:]
        for observation in qualityRequest.results ?? [] {
            if let quality = observation.faceCaptureQuality {
                qualities[observation.uuid] = quality
            }
        }
        return (observations, qualities)
    }

    /// The classifier's highest person-label confidence for a square twice the size of the face
    /// box (Vision's bottom-left normalized box), centred on it and kept inside the photo: the
    /// face with its head and shoulders, which the classifier needs to see a person.
    static func personConfidence(around box: CGRect, in image: CGImage) throws -> Float {
        let width = Double(image.width), height = Double(image.height)
        let side = max(box.width * width, box.height * height) * 2
        let centre = CGPoint(x: box.midX * width, y: (1 - box.midY) * height)
        let square = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard let surround = image.cropping(to: square) else {
            throw AnalysisError.cropFailed
        }
        let request = VNClassifyImageRequest()
        request.revision = VNClassifyImageRequestRevision2
        try VNImageRequestHandler(cgImage: surround).perform([request])
        return (request.results ?? []).filter { personLabels.contains($0.identifier) }.map(\.confidence).max() ?? 0
    }

    enum AnalysisError: Error {
        case cropFailed
    }

    private func embeddingModel() throws(FaceAnalysisError) -> FaceEmbeddingModel {
        if let model {
            return model
        }
        let start = ContinuousClock.now
        do {
            let loaded = try FaceEmbeddingModel(bundle: bundle)
            model = loaded
            OtosLog.metadata.noticeOperation("face.model", phase: "loaded", fields: [
                "model": FaceEmbeddingModel.resourceName, "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
            ])
            return loaded
        } catch {
            OtosLog.metadata.errorOperation("face.model", phase: "loadFailed", fields: [
                "model": FaceEmbeddingModel.resourceName, "error": String(describing: error),
            ])
            throw .modelUnavailable(description: String(describing: error))
        }
    }

    /// The five alignment points in the photo's pixels, bottom-left origin: the two eye centres
    /// (left to right in the image), the lowest nose-crest point as the nose tip, and the
    /// leftmost and rightmost outer-lip points as the mouth corners.
    static func alignmentPoints(_ observation: VNFaceObservation, imageSize: CGSize) -> FaceAlignment.Landmarks? {
        guard let landmarks = observation.landmarks,
              let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye,
              let noseCrest = landmarks.noseCrest, let lips = landmarks.outerLips
        else {
            return nil
        }
        func centre(_ region: VNFaceLandmarkRegion2D) -> CGPoint? {
            let points = region.pointsInImage(imageSize: imageSize)
            guard !points.isEmpty else { return nil }
            let count = Double(points.count)
            return CGPoint(x: points.map(\.x).reduce(0, +) / count, y: points.map(\.y).reduce(0, +) / count)
        }
        let lipPoints = lips.pointsInImage(imageSize: imageSize)
        guard let left = centre(leftEye), let right = centre(rightEye),
              let nose = noseCrest.pointsInImage(imageSize: imageSize).min(by: { $0.y < $1.y }),
              let mouthLeft = lipPoints.min(by: { $0.x < $1.x }),
              let mouthRight = lipPoints.max(by: { $0.x < $1.x })
        else {
            return nil
        }
        return FaceAlignment.Landmarks(
            leftEye: left.x <= right.x ? left : right,
            rightEye: left.x <= right.x ? right : left,
            nose: nose,
            leftMouth: mouthLeft,
            rightMouth: mouthRight
        )
    }

    /// The aligned 112 × 112 crop of `source` under `transform`, made opaque: where the face
    /// reaches past the photo's edge the crop is black, never transparent. A crop with
    /// transparent pixels embeds differently depending on how it is read (cosine as low as
    /// 0.92 measured against the same crop flattened another way), so the model is only ever
    /// handed opaque pixels.
    static func alignedCrop(of source: CIImage, transform: CGAffineTransform, context: CIContext) -> CGImage? {
        let frame = CGRect(x: 0, y: 0, width: FaceAlignment.side, height: FaceAlignment.side)
        let black = CIImage(color: .black).cropped(to: frame)
        let aligned = source.transformed(by: transform).composited(over: black).cropped(to: frame)
        return context.createCGImage(aligned, from: frame)
    }

    /// Vision's bottom-left normalized box as a top-left one.
    private static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}
