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

    /// The five points the alignment maps: the two eye centres, the nose tip and the two
    /// mouth corners, left and right as they lie in the image. Named, so a set is always
    /// complete and two sets always pair up point for point.
    struct Landmarks: Equatable, Sendable {
        var leftEye: CGPoint
        var rightEye: CGPoint
        var nose: CGPoint
        var leftMouth: CGPoint
        var rightMouth: CGPoint

        /// The five points in the template's published order, the order the catalog stores.
        var points: [CGPoint] {
            [leftEye, rightEye, nose, leftMouth, rightMouth]
        }

        /// Nil unless `points` is exactly five, in the order `points` gives.
        init?(points: [CGPoint]) {
            guard points.count == 5 else { return nil }
            self.init(
                leftEye: points[0], rightEye: points[1], nose: points[2], leftMouth: points[3], rightMouth: points[4]
            )
        }

        init(leftEye: CGPoint, rightEye: CGPoint, nose: CGPoint, leftMouth: CGPoint, rightMouth: CGPoint) {
            self.leftEye = leftEye
            self.rightEye = rightEye
            self.nose = nose
            self.leftMouth = leftMouth
            self.rightMouth = rightMouth
        }

        /// Each point moved by `move`.
        func map(_ move: (CGPoint) -> CGPoint) -> Landmarks {
            Landmarks(
                leftEye: move(leftEye),
                rightEye: move(rightEye),
                nose: move(nose),
                leftMouth: move(leftMouth),
                rightMouth: move(rightMouth)
            )
        }

        func applying(_ transform: CGAffineTransform) -> Landmarks {
            map { $0.applying(transform) }
        }

        fileprivate var mean: CGPoint {
            CGPoint(
                x: (leftEye.x + rightEye.x + nose.x + leftMouth.x + rightMouth.x) / 5,
                y: (leftEye.y + rightEye.y + nose.y + leftMouth.y + rightMouth.y) / 5
            )
        }
    }

    /// The ArcFace template, flipped from its published top-left origin into the bottom-left
    /// one the transform works in.
    static let template = Landmarks(
        leftEye: published(38.2946, 51.6963),
        rightEye: published(73.5318, 51.5014),
        nose: published(56.0252, 71.7366),
        leftMouth: published(41.5493, 92.3655),
        rightMouth: published(70.7299, 92.2041)
    )

    /// A published template point, given as its distance from the left and from the top.
    private static func published(_ left: Double, _ top: Double) -> CGPoint {
        CGPoint(x: left, y: Double(side) - top)
    }

    /// The accepted range of the face box's height in pixels times the alignment scale. A real
    /// face maps to about the template's own face height (median 93 measured on a reference
    /// library's photos); below 50 Vision's landmarks were spread over the scene rather than one face, and
    /// above 150 the "face" was an object. Measured: 61 of 3,293 detections fall outside.
    static let admittedScaledHeight = 50.0 ... 150.0

    /// The least-squares similarity transform (rotation, uniform scale, translation) taking
    /// `source` onto `destination`, point for point; nil when the source points all coincide
    /// and so have no shape to align.
    ///
    /// It sums the five named points directly rather than walking arrays: in the Debug build
    /// the app ships as, each generic sequence step allocates, and that allocation cost, not
    /// this arithmetic, was what the alignment benchmark measured, varying with the heap
    /// (`docs/research/2026-11-10-face-align-benchmark-variance.md`).
    static func similarity(from source: Landmarks, to destination: Landmarks) -> CGAffineTransform? {
        let sourceMean = source.mean, destinationMean = destination.mean
        var moments = Moments(sourceMean: sourceMean, destinationMean: destinationMean)
        moments.add(source.leftEye, destination.leftEye)
        moments.add(source.rightEye, destination.rightEye)
        moments.add(source.nose, destination.nose)
        moments.add(source.leftMouth, destination.leftMouth)
        moments.add(source.rightMouth, destination.rightMouth)
        guard moments.norm > 0 else { return nil }
        let a = moments.dot / moments.norm, b = moments.cross / moments.norm
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

    /// The sums the least-squares fit reads, over point pairs taken about each set's mean.
    private struct Moments {
        let sourceMean: CGPoint
        let destinationMean: CGPoint
        var dot = 0.0
        var cross = 0.0
        var norm = 0.0

        mutating func add(_ point: CGPoint, _ target: CGPoint) {
            let sx = point.x - sourceMean.x, sy = point.y - sourceMean.y
            let dx = target.x - destinationMean.x, dy = target.y - destinationMean.y
            dot += sx * dx + sy * dy
            cross += sx * dy - sy * dx
            norm += sx * sx + sy * sy
        }
    }
}
