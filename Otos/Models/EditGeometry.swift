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
