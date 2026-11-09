import CoreGraphics
import Foundation

/// Face alignment guide
///
/// The geometry between a detected face and the 112 × 112 crop the embedding model reads
/// (ADR 0047). Five points (the two eye centres, the nose tip, the two mouth corners) are mapped
/// onto the ArcFace template by the least-squares similarity transform, the same alignment the
/// model was trained on and the bake-off measured
/// (`docs/research/2026-11-07-face-recognition-models.md`).
///
/// Everything here works in a bottom-left-origin pixel space, the one Core Image and Vision's
/// image coordinates use, so the transform applies directly to a `CIImage` of the photo.
nonisolated enum FaceAlignment {
    /// The model's input side, in pixels.
    static let side = 112

    /// The ArcFace template (top-left origin, as published): left eye, right eye, nose tip,
    /// left mouth corner, right mouth corner.
    private static let publishedTemplate: [(Double, Double)] = [
        (38.2946, 51.6963), (73.5318, 51.5014), (56.0252, 71.7366), (41.5493, 92.3655), (70.7299, 92.2041),
    ]

    /// The template in the bottom-left origin the transform works in.
    static let template: [CGPoint] = publishedTemplate.map { CGPoint(x: $0.0, y: Double(side) - $0.1) }

    /// The accepted range of the face box's height in pixels times the alignment scale. A real
    /// face maps to about the template's own face height (median 93 measured on the owner's
    /// photos); below 50 Vision's landmarks were spread over the scene rather than one face, and
    /// above 150 the "face" was an object. Measured: 61 of 3,293 detections fall outside.
    static let admittedScaledHeight = 50.0 ... 150.0

    /// The least-squares similarity transform (rotation, uniform scale, translation) taking
    /// `source` onto `destination`, point for point; nil when the source points all coincide
    /// and so have no shape to align.
    static func similarity(from source: [CGPoint], to destination: [CGPoint]) -> CGAffineTransform? {
        precondition(source.count == destination.count && !source.isEmpty)
        let sourceMean = mean(source), destinationMean = mean(destination)
        var dot = 0.0, cross = 0.0, norm = 0.0
        for (point, target) in zip(source, destination) {
            let sx = point.x - sourceMean.x, sy = point.y - sourceMean.y
            let dx = target.x - destinationMean.x, dy = target.y - destinationMean.y
            dot += sx * dx + sy * dy
            cross += sx * dy - sy * dx
            norm += sx * sx + sy * sy
        }
        guard norm > 0 else { return nil }
        let a = dot / norm, b = cross / norm
        return CGAffineTransform(
            a: a, b: b, c: -b, d: a,
            tx: destinationMean.x - (a * sourceMean.x - b * sourceMean.y),
            ty: destinationMean.y - (b * sourceMean.x + a * sourceMean.y)
        )
    }

    /// The uniform scale of a similarity transform.
    static func scale(of transform: CGAffineTransform) -> Double {
        (transform.a * transform.a + transform.b * transform.b).squareRoot()
    }

    /// Whether a face whose box is `boxHeight` pixels tall and whose alignment has `transform`
    /// is a face the model should read.
    static func admits(boxHeight: Double, transform: CGAffineTransform) -> Bool {
        admittedScaledHeight.contains(boxHeight * scale(of: transform))
    }

    private static func mean(_ points: [CGPoint]) -> CGPoint {
        let count = Double(points.count)
        return CGPoint(x: points.map(\.x).reduce(0, +) / count, y: points.map(\.y).reduce(0, +) / count)
    }
}
