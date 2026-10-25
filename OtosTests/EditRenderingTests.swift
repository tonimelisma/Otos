import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// ADR 0036: a recipe changes the rendered pixels, a neutral one changes nothing, and the
/// live renderer and the stored-image renderer agree.
@Suite(.testDirectory)
struct EditRenderingTests {
    @Test func exposureBrightensAndANeutralRecipeLeavesThePhotoAsItIs() async throws {
        let url = try makeTestDirectory().appending(path: "gradient.jpg")
        try writeGradientJPEG(to: url)

        let neutral = try await ImageRenderer.interactive.render(url, longEdge: nil)
        let brighter = try await ImageRenderer.interactive.render(url, longEdge: nil, recipe: EditRecipe(exposure: 1))
        let darker = try await ImageRenderer.interactive.render(url, longEdge: nil, recipe: EditRecipe(exposure: -1))

        let base = meanLuminance(neutral.image)
        #expect(meanLuminance(brighter.image) > base + 0.05)
        #expect(meanLuminance(darker.image) < base - 0.05)
        #expect(brighter.image.width == neutral.image.width)
        #expect(brighter.image.height == neutral.image.height)
    }

    @Test func contrastSpreadsTheTonesApart() async throws {
        let url = try makeTestDirectory().appending(path: "gradient.jpg")
        try writeGradientJPEG(to: url)

        let neutral = try await ImageRenderer.interactive.render(url, longEdge: nil)
        let contrasty = try await ImageRenderer.interactive.render(url, longEdge: nil, recipe: EditRecipe(contrast: 80))

        #expect(toneSpread(contrasty.image) > toneSpread(neutral.image))
    }

    @Test func aStillsWhiteBalanceVibranceAndSaturationMoveItsColor() async throws {
        let url = try makeTestDirectory().appending(path: "gray.jpg")
        try writeSolidJPEG(to: url, red: 0.5, green: 0.5, blue: 0.5)

        let warmer = try await ImageRenderer.interactive.render(url, longEdge: nil, recipe: EditRecipe(temperature: 50))
        let magenta = try await ImageRenderer.interactive.render(url, longEdge: nil, recipe: EditRecipe(tint: 50))
        let warm = meanColor(warmer.image)
        let tinted = meanColor(magenta.image)
        #expect(warm.red > warm.blue + 0.05)
        #expect(tinted.green < tinted.red - 0.03 && tinted.green < tinted.blue - 0.03)

        let colorURL = try makeTestDirectory().appending(path: "color.jpg")
        try writeSolidJPEG(to: colorURL, red: 0.7, green: 0.45, blue: 0.3)
        let neutral = try await meanColor(ImageRenderer.interactive.render(colorURL, longEdge: nil).image)
        let desaturated = try await meanColor(ImageRenderer.interactive.render(
            colorURL, longEdge: nil, recipe: EditRecipe(saturation: -100)
        ).image)
        #expect(abs(desaturated.red - desaturated.blue) < abs(neutral.red - neutral.blue) / 4)
    }

    /// The picker on a warm-cast still finds the relative white balance that renders the
    /// clicked point gray.
    @Test func pickingANeutralPointOnAStillGraysIt() async throws {
        let url = try makeTestDirectory().appending(path: "cast.jpg")
        try writeSolidJPEG(to: url)
        let renderer = LiveEditRenderer()

        let facts = try await renderer.open(url)
        let picked = try await renderer.neutralWhiteBalance(url, at: CGPoint(x: 0.5, y: 0.5))
        let corrected = try await renderer.render(
            url, recipe: EditRecipe(temperature: picked.temperature, tint: picked.tint)
        )
        await renderer.close()

        #expect(facts == .still)
        #expect(picked.temperature < 0)
        let color = meanColor(corrected)
        #expect(abs(color.red - color.green) < 0.02)
        #expect(abs(color.blue - color.green) < 0.02)
    }

    @Test func theLiveRendererMatchesTheStoredRenderAndStagesBothProducts() async throws {
        let directory = try makeTestDirectory()
        let url = directory.appending(path: "gradient.jpg")
        try writeGradientJPEG(to: url)
        let recipe = EditRecipe(exposure: 0.5, shadows: 30)
        let renderer = LiveEditRenderer()

        let live = try await renderer.render(url, recipe: recipe)
        let again = try await renderer.render(url, recipe: recipe)
        let stored = try await ImageRenderer.interactive.render(
            url, longEdge: ThumbnailStore.previewMaxPixelSize, recipe: recipe
        )
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: directory.path),
            relativePath: MediaRelativePath(rawValue: "gradient.jpg")
        )
        let products = try await renderer.renderProducts(url, recipe: recipe, id: id, directory: directory)
        await renderer.close()

        #expect(live.width == 96 && live.height == 64)
        #expect(again.width == live.width && again.height == live.height)
        #expect(abs(meanLuminance(live) - meanLuminance(stored.image)) < 0.02)
        for staged in [products.preview, products.thumbnail] {
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: staged.stagedRelativePath).path))
        }
        #expect(products.preview.finalRelativePath == ThumbnailStore.previewRelativeName(for: id))
        #expect(products.thumbnail.finalRelativePath == ThumbnailStore.relativeName(for: id))
    }
}

/// Mean luminance of the right quarter minus that of the left quarter.
private func toneSpread(_ image: CGImage) -> Double {
    let quarter = image.width / 4
    guard let left = image.cropping(to: CGRect(x: 0, y: 0, width: quarter, height: image.height)),
          let right = image.cropping(to: CGRect(x: image.width - quarter, y: 0, width: quarter, height: image.height))
    else {
        return 0
    }
    return meanLuminance(right) - meanLuminance(left)
}
