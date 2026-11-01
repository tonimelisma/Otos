import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// ADR 0036 geometry: quarter turns and flips in the displayed frame, then straighten,
/// then crop — as recipe math, as rendered pixels, and back again for the picker.
@Suite(.testDirectory)
struct EditGeometryTests {
    @Test func fourQuarterTurnsAndTwoFlipsComeBackToTheStart() {
        let crop = EditCrop(left: 0.1, top: 0.2, width: 0.3, height: 0.4)
        var recipe = EditRecipe(straighten: 5, crop: crop)
        for _ in 0 ..< 4 {
            recipe = recipe.turned(clockwise: true)
        }
        #expect(recipe.quarterTurns == 0)
        #expect(abs((recipe.crop?.left ?? 0) - 0.1) < 1e-9 && abs((recipe.crop?.width ?? 0) - 0.3) < 1e-9)
        let flippedTwice = recipe.flipped(horizontally: true).flipped(horizontally: true)
        #expect(flippedTwice.flipHorizontal == false && flippedTwice.straighten == 5)
        #expect(abs((flippedTwice.crop?.left ?? 0) - 0.1) < 1e-9)
    }

    /// A mirror reverses a rotation's sense: turning a once-flipped photo right is a left
    /// turn of what lies under the flip, and flipping reverses the straighten angle.
    @Test func aTurnOverOneFlipMovesTheOtherWayAndAFlipReversesStraighten() {
        let flipped = EditRecipe(straighten: 4).flipped(horizontally: true)
        #expect(flipped.straighten == -4)
        #expect(flipped.turned(clockwise: true).quarterTurns == 3)
        #expect(EditRecipe().turned(clockwise: true).quarterTurns == 1)
        #expect(EditRecipe().turned(clockwise: false).quarterTurns == 3)
    }

    @Test func theEditedSizeFollowsTurnsAndTheCrop() {
        let original = CGSize(width: 6000, height: 4000)
        #expect(EditRecipe(quarterTurns: 1).outputSize(ofOriginal: original) == CGSize(width: 4000, height: 6000))
        let cropped = EditRecipe(crop: EditCrop(left: 0, top: 0, width: 0.5, height: 0.25))
        #expect(cropped.outputSize(ofOriginal: original) == CGSize(width: 3000, height: 1000))
        #expect(abs(cropped.cropLongEdgeFraction(ofOriginal: original) - 0.5) < 1e-9)
    }

    @Test func dragsMoveAndResizeTheCropInsideTheFrame() {
        let crop = EditCrop(left: 0.2, top: 0.2, width: 0.4, height: 0.4)
        #expect(crop.moved(by: CGSize(width: 0.9, height: 0)) == EditCrop(left: 0.6, top: 0.2, width: 0.4, height: 0.4))
        let free = crop.resized(.bottomRight, by: CGSize(width: 0.1, height: 0.3), fractionRatio: nil)
        #expect(abs(free.width - 0.5) < 1e-9 && abs(free.height - 0.7) < 1e-9 && free.left == 0.2)
        let square = crop.resized(.bottomRight, by: CGSize(width: 0.1, height: 0.3), fractionRatio: 1)
        #expect(abs(square.width - square.height) < 1e-9)
        #expect(abs(square.width - 0.7) < 1e-9 && square.left == 0.2 && square.top == 0.2)
        let edge = crop.resized(.right, by: CGSize(width: 0.2, height: 0), fractionRatio: 1)
        #expect(abs(edge.width - 0.6) < 1e-9 && abs(edge.center.y - crop.center.y) < 1e-9)
        let tooFar = crop.resized(.bottomRight, by: CGSize(width: 2, height: 2), fractionRatio: 1)
        #expect(tooFar.right <= 1 + 1e-9 && tooFar.bottom <= 1 + 1e-9)
        #expect(abs(tooFar.width - tooFar.height) < 1e-9)
    }

    @Test func anAspectIsTheLargestOfItsShapeInTheFrame() {
        let frame = CGSize(width: 96, height: 64)
        let square = EditCrop.largest(pixelRatio: 1, frame: frame, around: CGPoint(x: 0.5, y: 0.5))
        #expect(abs(square.width - 64.0 / 96) < 1e-9 && abs(square.height - 1) < 1e-9)
        #expect(abs(square.center.x - 0.5) < 1e-9)
        #expect(CropAspect.original.longOverShort(frame: CGSize(width: 96, height: 64)) == 1.5)
        #expect(CropAspect.free.longOverShort(frame: CGSize(width: 96, height: 64)) == nil)
    }

    @Test func aPointOnTheEditedPhotoMapsBackToTheDevelopedOne() {
        let size = CGSize(width: 96, height: 64)
        let turned = EditGeometry(recipe: EditRecipe(quarterTurns: 1), developedSize: size)
        #expect(turned.frameSize == CGSize(width: 64, height: 96))
        let topLeft = turned.developedPoint(atEditedFraction: .zero)
        #expect(abs(topLeft.x) < 1e-9 && abs(topLeft.y) < 1e-9)
        let cropped = EditGeometry(
            recipe: EditRecipe(crop: EditCrop(left: 0.5, top: 0, width: 0.5, height: 1)),
            developedSize: size
        )
        let middle = cropped.developedPoint(atEditedFraction: CGPoint(x: 0.5, y: 0.5))
        #expect(abs(middle.x - 72) < 1e-9 && abs(middle.y - 32) < 1e-9)
        #expect(abs(EditGeometry.fillScale(degrees: 45, frame: CGSize(width: 10, height: 10)) - 2.squareRoot()) < 1e-9)
        #expect(EditGeometry.fillScale(degrees: 0, frame: size) == 1)
    }

    @Test func turnsFlipsAndCropsMoveThePixels() async throws {
        let url = try makeTestDirectory().appending(path: "split.jpg")
        try writeSplitJPEG(to: url)

        let turned = try await ImageRenderer.interactive.render(url, longEdge: nil, recipe: EditRecipe(quarterTurns: 1))
        #expect(turned.image.width == 64 && turned.image.height == 96)
        // The left half (red) is the top half after a clockwise turn.
        let top = try meanColor(turned.image, in: CGRect(x: 8, y: 8, width: 48, height: 32))
        #expect(top.red > 0.6 && top.blue < 0.3)

        let flipped = try await ImageRenderer.interactive.render(
            url, longEdge: nil, recipe: EditRecipe(flipHorizontal: true)
        )
        let left = try meanColor(flipped.image, in: CGRect(x: 4, y: 8, width: 32, height: 48))
        #expect(left.blue > 0.6 && left.red < 0.3)

        let cropped = try await ImageRenderer.interactive.render(
            url, longEdge: nil, recipe: EditRecipe(crop: EditCrop(left: 0, top: 0, width: 0.5, height: 1))
        )
        #expect(cropped.image.width == 48 && cropped.image.height == 64)
        let kept = meanColor(cropped.image)
        #expect(kept.red > 0.6 && kept.blue < 0.3)
    }

    /// Straighten keeps the frame's size and fills it to the corners.
    @Test func straighteningKeepsTheFrameFilled() async throws {
        let url = try makeTestDirectory().appending(path: "gray.jpg")
        try writeSolidJPEG(to: url, red: 0.6, green: 0.6, blue: 0.6)

        let straightened = try await ImageRenderer.interactive.render(
            url, longEdge: nil, recipe: EditRecipe(straighten: 12)
        )

        #expect(straightened.image.width == 64 && straightened.image.height == 48)
        let corner = try meanColor(straightened.image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        #expect(corner.green > 0.5)
    }

    /// A crop is developed from a frame large enough that the crop still reaches the
    /// requested size.
    @Test func aCropIsDevelopedLargeEnoughToReachTheRequestedSize() async throws {
        let url = try makeTestDirectory().appending(path: "split.jpg")
        try writeSplitJPEG(to: url)

        let rendered = try await ImageRenderer.interactive.render(
            url, longEdge: 64, recipe: EditRecipe(crop: EditCrop(left: 0, top: 0, width: 0.5, height: 1))
        )

        #expect(max(rendered.image.width, rendered.image.height) == 64)
    }

    /// A RAW's scale factor is a function of the native size read when it was opened: the
    /// edited long edge reaches the size asked for, a crop is developed larger, and nothing
    /// is developed beyond full resolution.
    @Test func aRAWsScaleFactorComesFromItsOpenedNativeSize() {
        let native = CGSize(width: 6192, height: 4128)
        #expect(ImageRenderer.rawScaleFactor(nativeSize: native, outputLongEdge: 2560, recipe: .neutral) == Float(2560.0 / 6192))
        // Half the width of a 6192 × 4128 frame is 3096 × 4128: its long edge is 4128.
        let halfCrop = EditRecipe(crop: EditCrop(left: 0, top: 0, width: 0.5, height: 1))
        #expect(ImageRenderer.rawScaleFactor(nativeSize: native, outputLongEdge: 2560, recipe: halfCrop) == Float(2560.0 / 4128))
        #expect(ImageRenderer.rawScaleFactor(nativeSize: native, outputLongEdge: 8000, recipe: .neutral) == 1)
        #expect(ImageRenderer.rawScaleFactor(nativeSize: native, outputLongEdge: nil, recipe: .neutral) == 1)
    }

    /// The picker samples the pixel under the click on the photo as shown: with the photo
    /// flipped, a click on its left half samples the original's right half.
    @Test func thePickerSamplesThePixelUnderTheClickThroughTheGeometry() async throws {
        let url = try makeTestDirectory().appending(path: "split.jpg")
        try writeSplitJPEG(
            to: url,
            left: CGColor(srgbRed: 0.62, green: 0.5, blue: 0.38, alpha: 1),
            right: CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        )
        let renderer = LiveEditRenderer()

        let plain = try await renderer.neutralWhiteBalance(url, at: CGPoint(x: 0.25, y: 0.5), shown: .neutral)
        let flipped = try await renderer.neutralWhiteBalance(
            url, at: CGPoint(x: 0.25, y: 0.5), shown: EditRecipe(flipHorizontal: true)
        )
        await renderer.close()

        #expect(plain.temperature < -5)
        #expect(abs(flipped.temperature) <= 2)
    }

    /// Auto straighten levels a horizon that rises to the right with a clockwise turn of
    /// the same angle, and reads the photo as it is turned: the same horizon on a photo
    /// flipped horizontally falls to the right, so it levels the other way.
    @Test func autoStraightenLevelsTheHorizonAsThePhotoIsShown() async throws {
        let url = try makeTestDirectory().appending(path: "horizon.jpg")
        try writeHorizonJPEG(to: url, risingBy: 6)
        let renderer = LiveEditRenderer()

        let plain = try #require(try await renderer.horizonStraighten(url, shown: .neutral))
        // Straighten and crop already on the photo do not change the reading.
        let edited = try #require(try await renderer.horizonStraighten(
            url, shown: EditRecipe(straighten: -20, crop: EditCrop(left: 0.1, top: 0.1, width: 0.5, height: 0.5))
        ))
        let flipped = try #require(try await renderer.horizonStraighten(url, shown: EditRecipe(flipHorizontal: true)))
        await renderer.close()

        #expect(abs(plain - 6) < 1)
        #expect(abs(edited - plain) < 0.5)
        #expect(abs(flipped + 6) < 1)
    }
}
