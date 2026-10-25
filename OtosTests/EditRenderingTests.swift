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
