import CoreGraphics
@testable import OtosKit

extension DisplayImage {
    /// A `width` × `height` image of one gray, for a test that needs an image a tile, a pane
    /// or a cover holds. Each call makes a new image.
    static func fixture(width: Int = 8, height: Int? = nil, gray: CGFloat = 0.5) -> DisplayImage {
        let height = height ?? width
        // A fixture that cannot be made is a broken test host, not a test outcome.
        // swiftlint:disable:next force_unwrapping
        return DisplayImage.draw(width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { context in
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }!
    }
}

/// Whether two display images are the same image, as `===` asks of the `CGImage`s they show.
func === (lhs: DisplayImage?, rhs: DisplayImage?) -> Bool {
    lhs?.cgImage === rhs?.cgImage
}

func !== (lhs: DisplayImage?, rhs: DisplayImage?) -> Bool {
    !(lhs === rhs)
}

func === (lhs: DisplayImage, rhs: DisplayImage) -> Bool {
    lhs.isSame(as: rhs)
}

func !== (lhs: DisplayImage, rhs: DisplayImage) -> Bool {
    !lhs.isSame(as: rhs)
}
