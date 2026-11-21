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
    let developedSize: CGSize

    init(recipe: EditRecipe, developedSize: CGSize) {
        self.developedSize = developedSize
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

    /// The developed image's size for an edited photo of `editedSize` made with `recipe`:
    /// the crop is a fraction of the frame, and the frame is the developed image after its
    /// quarter turns, so the frame's shape follows from the edited photo's. Its scale is the
    /// edited photo's, which is all fractions of it need.
    static func developedSize(ofEdited editedSize: CGSize, recipe: EditRecipe) -> CGSize {
        let crop = recipe.crop ?? .whole
        guard crop.width > 0, crop.height > 0 else { return editedSize }
        let frame = CGSize(width: editedSize.width / crop.width, height: editedSize.height / crop.height)
        return recipe.quarterTurns % 2 == 0 ? frame : CGSize(width: frame.height, height: frame.width)
    }

    /// The point of the developed image shown at `point` of the edited photo, both as
    /// fractions of their width and height from the top-left corner: a face read from the
    /// stored preview, placed on the upright photo (ADR 0047).
    func developedFraction(atEditedFraction point: CGPoint) -> CGPoint {
        let developed = developedPoint(atEditedFraction: point)
        return CGPoint(x: developed.x / developedSize.width, y: 1 - developed.y / developedSize.height)
    }

    /// Where `rect` of the developed image shows on the edited photo, both as fractions from
    /// the top-left corner: the bounds of its corners after the geometry, clipped to the
    /// photo. Nil when none of it is inside the crop. A face's outline on the loupe.
    func editedRect(ofDevelopedFraction rect: CGRect) -> CGRect? {
        guard cropRect.width > 0, cropRect.height > 0 else { return nil }
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ].map { fraction in
            let frame = CGPoint(x: fraction.x * developedSize.width, y: (1 - fraction.y) * developedSize.height)
                .applying(transform)
            return CGPoint(
                x: (frame.x - cropRect.minX) / cropRect.width,
                y: (cropRect.maxY - frame.y) / cropRect.height
            )
        }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let clipped = bounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clipped.isNull || clipped.isEmpty ? nil : clipped
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
