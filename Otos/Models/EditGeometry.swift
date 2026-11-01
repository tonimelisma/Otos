import CoreGraphics
import Foundation

/// The recipe's geometry as one affine transform and a crop, for a developed image of a
/// given size (ADR 0036). Coordinates are Core Image's: origin bottom-left, y up.
///
/// The order is the recipe's: quarter turns clockwise, then flips, both in the displayed
/// frame; then straighten, which rotates about the frame's center and scales just enough
/// that the rotated photo still covers the whole frame, so no empty corner shows; then the
/// crop, a rectangle of that frame. Every step is affine, so a point on the edited photo
/// maps back to the developed image exactly — what the white balance picker needs.
nonisolated struct EditGeometry: Equatable {
    /// Developed image coordinates to frame coordinates.
    let transform: CGAffineTransform
    /// The frame: the developed image after quarter turns.
    let frameSize: CGSize
    /// The kept part of the frame, in frame coordinates.
    let cropRect: CGRect

    init(recipe: EditRecipe, developedSize: CGSize) {
        var transform = CGAffineTransform.identity
        var size = developedSize
        for _ in 0 ..< recipe.quarterTurns {
            // A quarter clockwise in y-up space, back onto the origin: (x, y) → (y, w − x).
            transform = transform.concatenating(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width))
            size = CGSize(width: size.height, height: size.width)
        }
        if recipe.flipHorizontal {
            transform = transform.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0))
        }
        if recipe.flipVertical {
            transform = transform.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height))
        }
        if recipe.straighten != 0 {
            transform = transform.concatenating(Self.straightening(recipe.straighten, frame: size))
        }
        let crop = recipe.crop ?? .whole
        self.transform = transform
        frameSize = size
        cropRect = CGRect(
            x: crop.left * size.width,
            y: (1 - crop.bottom) * size.height,
            width: crop.width * size.width,
            height: crop.height * size.height
        )
    }

    /// The point of the developed image shown at `point` of the edited photo, given as a
    /// fraction of its width and height from the top-left corner.
    func developedPoint(atEditedFraction point: CGPoint) -> CGPoint {
        let framePoint = CGPoint(
            x: cropRect.minX + point.x * cropRect.width,
            y: cropRect.maxY - point.y * cropRect.height
        )
        return framePoint.applying(transform.inverted())
    }

    /// The scale at which a frame of `size` rotated by `angle` still covers itself.
    static func fillScale(degrees: Double, frame size: CGSize) -> Double {
        let radians = abs(degrees) * .pi / 180
        guard size.width > 0, size.height > 0 else { return 1 }
        let aspect = max(size.width / size.height, size.height / size.width)
        return cos(radians) + sin(radians) * aspect
    }

    /// Rotates `degrees` clockwise about the frame's center and scales to fill it.
    private static func straightening(_ degrees: Double, frame size: CGSize) -> CGAffineTransform {
        let scale = fillScale(degrees: degrees, frame: size)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGAffineTransform(translationX: -center.x, y: -center.y)
            // Clockwise on screen is a negative angle in y-up space.
            .concatenating(CGAffineTransform(rotationAngle: -degrees * .pi / 180))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }
}

/// The crop tool's straighten line (Lightroom Classic's Angle tool): the clockwise turn, in
/// degrees, that makes a line drawn from `start` to `end` on the photo as shown level — or
/// plumb, when it is drawn nearer vertical than horizontal. Points are in a y-down space
/// (the pane's), where a line falling to the right is turned clockwise from horizontal, so
/// leveling it turns the photo counterclockwise. Nil for a line too short to have a
/// direction.
nonisolated enum StraightenLine {
    /// Shorter than this, in the space's units, a drag is a click, not a line.
    static let minimumLength: Double = 8

    static func levelingTurn(from start: CGPoint, to end: CGPoint) -> Double? {
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        guard (dx * dx + dy * dy).squareRoot() >= minimumLength else { return nil }
        // The line's tilt from horizontal, clockwise positive, folded into −90…90.
        var tilt = atan2(dy, dx) * 180 / .pi
        if tilt > 90 {
            tilt -= 180
        }
        if tilt <= -90 {
            tilt += 180
        }
        // Nearer vertical: the tilt from plumb is what levels it.
        if tilt > 45 {
            tilt -= 90
        }
        if tilt < -45 {
            tilt += 90
        }
        return -tilt
    }
}

/// A suggested crop (the crop tool's Suggested menu), placed by the subject Vision finds in
/// the frame. Both keep the aspect the tool constrains, or the frame's own when it is free.
nonisolated enum CropSuggestion: String, CaseIterable, Identifiable, Sendable {
    /// The smallest crop of the aspect that holds the subject with a margin around it.
    case fitSubject
    /// The largest crop of the aspect, placed so the subject's center falls on the
    /// rule-of-thirds point on its side of the frame.
    case subjectOnThirds

    /// The margin around the subject, as a share of its size on each side.
    static let subjectMargin = 0.15

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .fitSubject: "Fit Subject"
        case .subjectOnThirds: "Subject on Thirds"
        }
    }

    /// The panel's button title, short enough for two beside the row's label.
    var shortTitle: String {
        switch self {
        case .fitSubject: "Subject"
        case .subjectOnThirds: "Thirds"
        }
    }

    var help: String {
        switch self {
        case .fitSubject: "Crop close around the subject"
        case .subjectOnThirds: "Crop with the subject on a third"
        }
    }

    /// The crop, in fractions of a frame of `frame` pixels, for a subject at `subject` (fractions
    /// of the frame from its top-left corner), keeping `pixelRatio` (width over height in pixels)
    /// or the frame's own when nil.
    func crop(subject: CGRect, frame: CGSize, pixelRatio: Double?) -> EditCrop {
        guard frame.width > 0, frame.height > 0 else { return .whole }
        let ratio = pixelRatio ?? Double(frame.width / frame.height)
        let center = CGPoint(x: subject.midX, y: subject.midY)
        let largest = EditCrop.largest(pixelRatio: ratio, frame: frame, around: center)
        switch self {
        case .fitSubject:
            // The subject and its margin in pixels, grown on one axis to the aspect.
            var width = Double(subject.width * frame.width) * (1 + 2 * Self.subjectMargin)
            var height = Double(subject.height * frame.height) * (1 + 2 * Self.subjectMargin)
            if width / height > ratio {
                height = width / ratio
            } else {
                width = height * ratio
            }
            // Never larger than the largest crop of the aspect the frame holds.
            let scale = min(1, largest.width * Double(frame.width) / width)
            let fractionWidth = width * scale / Double(frame.width)
            let fractionHeight = height * scale / Double(frame.height)
            return EditCrop(
                left: center.x - fractionWidth / 2,
                top: center.y - fractionHeight / 2,
                width: fractionWidth,
                height: fractionHeight
            ).clamped
        case .subjectOnThirds:
            let thirdX = center.x < 0.5 ? 1.0 / 3 : 2.0 / 3
            let thirdY = center.y < 0.5 ? 1.0 / 3 : 2.0 / 3
            return EditCrop(
                left: center.x - thirdX * largest.width,
                top: center.y - thirdY * largest.height,
                width: largest.width,
                height: largest.height
            ).clamped
        }
    }
}
