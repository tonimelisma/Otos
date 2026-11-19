import CoreGraphics
import Foundation

/// Which full-size preview slot a decode belongs to. Loupe and compare-left are
/// distinct slots even when they happen to show the same asset across mode switches.
nonisolated enum PaneSlot: CaseIterable, Hashable {
    case loupe
    case compareLeft
    case compareRight
}

/// A full-size decode bound to the asset it belongs to. Views render `image` only
/// when `id` matches the pane's expected asset; otherwise they fall back to the
/// id-keyed enrichment thumbnail. That identity check is what makes stale decodes
/// harmless — no generation counters required.
nonisolated struct PanePreview: Equatable {
    let id: MediaAssetID
    let image: DisplayImage
    let mediaChoice: MediaChoice?
    /// The original's upright pixel size when the decode reported one. With `editRecipe` it
    /// is the geometry the image was rendered with: the loupe sizes its zoom document from
    /// it, so 100 percent means native pixels even while the held `image` is the fit-size
    /// decode (APP-040), and a face box is carried through it onto the picture (ADR 0047).
    let uprightPixelSize: CGSize?
    /// The edit the image shows (ADR 0036); nil for an unedited photo and for Show Original.
    let editRecipe: EditRecipe?
    /// The edit revision the decode shows (ADR 0036): the detail's rendered revision when
    /// it was requested. A live edit render stays on screen until this reaches its save.
    let renderedRevision: Int64

    init(
        id: MediaAssetID,
        image: DisplayImage,
        mediaChoice: MediaChoice? = nil,
        uprightPixelSize: CGSize? = nil,
        editRecipe: EditRecipe? = nil,
        renderedRevision: Int64 = 0
    ) {
        self.id = id
        self.image = image
        self.mediaChoice = mediaChoice
        self.uprightPixelSize = uprightPixelSize
        self.editRecipe = editRecipe
        self.renderedRevision = renderedRevision
    }

    /// The pixel size of the photo as shown: what the edit's geometry makes of the original.
    var nativePixelSize: CGSize? {
        uprightPixelSize.map { size in editRecipe.map { $0.outputSize(ofOriginal: size) } ?? size }
    }

    /// Face boxes, fractions of the upright photo, placed on this image: through its edit's
    /// crop and straighten, as fractions of the image from its top-left corner. A box that
    /// cannot be placed is left out rather than drawn in the wrong place.
    func faceOutlines(_ boxes: [CGRect]) -> [CGRect] {
        boxes.compactMap { FaceOutline.onEditedPhoto($0, recipe: editRecipe, upright: uprightPixelSize) }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.image.isSame(as: rhs.image) && lhs.mediaChoice == rhs.mediaChoice
            && lhs.uprightPixelSize == rhs.uprightPixelSize && lhs.editRecipe == rhs.editRecipe
            && lhs.renderedRevision == rhs.renderedRevision
    }
}
