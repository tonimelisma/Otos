import AppKit
import ImageIO
import OSLog
import SwiftUI

// Face tiles (`docs/design/people.md`, DES-110): a square cut from the photo's stored
// preview (ADR 0035), or the stored frame of a video the face was read in (ADR 0047), around the face, the box enlarged by 1.6 and kept inside the photo.
// The preview shows the saved edit, so the box, a fraction of the upright photo, is first
// carried through that edit's quarter turns, flips, straighten and crop (`EditGeometry`).
// Before the first decode the tile shows the `person.crop.square` glyph, and its slash
// variant when the preview cannot be read or the edit's crop leaves the face out. A tile that has painted keeps its image for the
// same face: the view holds it, and `FaceTileImages` gives it back to a view made again for
// the same face (a row closing up, a list switch), so it never blanks (the grid's no-blank
// rule applied to faces).

/// Decoded face crops for this process, by face, box and preview with its edit. A bounded
/// cache: what it drops is decoded again from the stored preview. A new rendering keeps the
/// preview's name, so its edit is part of the key.
@MainActor
final class FaceTileImages {
    nonisolated struct Key: Hashable {
        let face: FaceID
        let box: CGRect
        let preview: FacePreview
    }

    private final nonisolated class Entry {
        let image: CGImage
        init(_ image: CGImage) {
            self.image = image
        }
    }

    private final nonisolated class KeyBox: NSObject {
        let key: Key
        init(_ key: Key) {
            self.key = key
        }

        override var hash: Int {
            key.hashValue
        }

        override func isEqual(_ object: Any?) -> Bool {
            (object as? KeyBox)?.key == key
        }
    }

    private let cache: NSCache<KeyBox, Entry> = {
        let cache = NSCache<KeyBox, Entry>()
        // About 190 gallery tiles at 256 px, several screenfuls of the gallery, or 2,400 of
        // the Info pane's at 80 px. Each entry owns its pixels (`FaceCrop.crop`), so its cost
        // is what it holds and what dropping it gives back.
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    func image(for key: Key) -> CGImage? {
        cache.object(forKey: KeyBox(key))?.image
    }

    func store(_ image: CGImage, for key: Key) {
        cache.setObject(Entry(image), forKey: KeyBox(key), cost: image.bytesPerRow * image.height)
    }
}

/// One face, cut from its photo's stored preview.
struct FaceTileView: View {
    let tile: FaceTile
    let edge: CGFloat
    let isSelected: Bool
    let images: FaceTileImages?
    let derivedImageDirectory: URL?

    @State private var image: CGImage?
    @State private var unavailable = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: edge, height: edge)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignPalette.hairline(for: colorScheme))
                Image(systemName: unavailable ? "person.slash" : "person.crop.square")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: edge, height: edge)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .task(id: tile) {
            await load()
        }
    }

    private func load() async {
        guard let preview = tile.preview else {
            return
        }
        let key = FaceTileImages.Key(face: tile.id, box: tile.box, preview: preview)
        if let cached = images?.image(for: key) {
            image = cached
            return
        }
        guard let derivedImageDirectory else { return }
        let pixels = Int((edge * displayScale).rounded(.up))
        guard let decoded = await FaceCrop.decode(tile.box, from: preview, in: derivedImageDirectory, pixelEdge: pixels) else {
            if !Task.isCancelled, image == nil {
                unavailable = true
            }
            return
        }
        guard !Task.isCancelled else { return }
        images?.store(decoded, for: key)
        image = decoded
    }
}

/// The crop, off the main actor.
nonisolated enum FaceCrop {
    /// How much larger than the face box the tile shows.
    static let enlargement: CGFloat = 1.6

    /// The tile for `box`, cut from the preview at no more than `pixelEdge` on a side. An
    /// upright preview, as every one Otos writes is, is never decoded whole: the cut is drawn
    /// from the uncached image, so Image I/O decodes only the part of the preview the face
    /// covers (`docs/research/2026-11-16-image-memory-while-used.md`). A turned one is first
    /// decoded upright at the tile's scale.
    @concurrent
    static func decode(_ box: CGRect, from preview: FacePreview, in directory: URL, pixelEdge: Int) async -> CGImage? {
        let signpost = OtosSignpost.thumbnails.beginInterval("FaceTileDecode")
        defer { OtosSignpost.thumbnails.endInterval("FaceTileDecode", signpost) }
        let url = ThumbnailStore.url(for: preview.name, in: directory)
        let uncached = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, uncached),
              preview.image < CGImageSourceGetCount(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, preview.image, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            OtosLog.thumbnails.debugOperation("people.faceTile", phase: "unreadable", fields: ["name": preview.name])
            return nil
        }
        // Orientations 5–8 turn the stored pixels a quarter.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let shown = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        guard let onPreview = self.box(box, onPreviewOf: shown, recipe: preview.recipe) else {
            OtosLog.thumbnails.debugOperation("people.faceTile", phase: "outsideCrop", fields: ["name": preview.name])
            return nil
        }
        let image: CGImage?
        if orientation == 1 {
            image = CGImageSourceCreateImageAtIndex(source, preview.image, uncached)
        } else {
            let side = max(onPreview.width * shown.width, onPreview.height * shown.height) * enlargement
            guard side > 0 else { return nil }
            let scale = min(1, CGFloat(pixelEdge) / side)
            image = CGImageSourceCreateThumbnailAtIndex(source, preview.image, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceThumbnailMaxPixelSize: Int((max(shown.width, shown.height) * scale).rounded(.up)),
            ] as CFDictionary)
        }
        guard let image else { return nil }
        return crop(image, box: onPreview, pixelEdge: pixelEdge)
    }

    /// Where `box`, a fraction of the upright photo, shows on a preview of `size` made with
    /// `recipe`, as a fraction of it from the top-left corner: the part inside the crop, nil
    /// when the crop leaves all of it out. The preview's shape fixes the upright photo's
    /// (`EditGeometry.developedSize(ofEdited:recipe:)`), which is all fractions need.
    static func box(_ box: CGRect, onPreviewOf size: CGSize, recipe: EditRecipe) -> CGRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        let upright = EditGeometry.developedSize(ofEdited: size, recipe: recipe)
        return EditGeometry(recipe: recipe, developedSize: upright).editedRect(ofDevelopedFraction: box)
    }

    /// The square around `box` (fractions, top-left origin), enlarged and kept inside the
    /// image, drawn at no more than `pixelEdge` on a side into pixels of its own
    /// (`MappedImage`): a crop sharing `image`'s pixels would keep all of `image` alive for as
    /// long as the tile is held. Smaller than asked only when the image is.
    static func crop(_ image: CGImage, box: CGRect, pixelEdge: Int = .max) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        var side = max(box.width * width, box.height * height) * enlargement
        side = min(side, width, height)
        let center = CGPoint(x: box.midX * width, y: box.midY * height)
        let x = min(max(center.x - side / 2, 0), width - side)
        let y = min(max(center.y - side / 2, 0), height - side)
        guard let region = image.cropping(to: CGRect(x: x, y: y, width: side, height: side).integral) else {
            return nil
        }
        let edge = min(pixelEdge, region.width, region.height)
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let colorSpace else { return nil }
        return MappedImage.draw(width: edge, height: edge, colorSpace: colorSpace) { context in
            context.interpolationQuality = .high
            context.draw(region, in: CGRect(x: 0, y: 0, width: edge, height: edge))
        }
    }
}
