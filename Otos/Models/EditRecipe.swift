import CoreGraphics
import Foundation

/// One photo's current edit (ADR 0036): the values of every control the
/// edit panel offers, applied on top of the original when it is rendered. The original
/// is never changed (decision 2). A value at its neutral point changes nothing, and a
/// recipe whose every value is neutral renders exactly as the unedited photo.
///
/// Stored as JSON in `media_asset.edit_recipe_json` (ADR 0036), so adding a control is a
/// new optional field rather than a schema change; a field a recipe does not carry
/// decodes as neutral.
nonisolated struct EditRecipe: Codable, Equatable, Hashable, Sendable {
    /// Light
    /// Exposure in stops. A RAW applies it in the RAW pipeline (`CIRAWFilter.exposure`);
    /// any other still through `CIExposureAdjust`.
    var exposure: Double = 0
    /// −100…100, applied through `CIColorControls` contrast.
    var contrast: Double = 0
    /// −100…0: recovers highlights through `CIHighlightShadowAdjust`, which can only
    /// darken them.
    var highlights: Double = 0
    /// −100…100, through `CIHighlightShadowAdjust`'s shadow amount.
    var shadows: Double = 0

    /// Color
    /// White balance temperature; nil is as shot. A RAW holds kelvin
    /// (`CIRAWFilter.neutralTemperature`, 2000–50000); any other still a relative
    /// −100…100 shift through `CITemperatureAndTint`, positive warmer.
    var temperature: Double?
    /// White balance tint; nil is as shot. A RAW holds `CIRAWFilter.neutralTint`
    /// (−150…150); any other still a relative −100…100. Positive is magenta.
    var tint: Double?
    /// −100…100 through `CIVibrance`.
    var vibrance: Double = 0
    /// −100…100 through `CIColorControls` saturation.
    var saturation: Double = 0

    // Effects: a vignette on the edited photo, after its crop.
    /// −100…100 through `CIVignetteEffect`; negative darkens the corners, as in Lightroom.
    var vignette: Double = 0
    /// 0…100: how far from the center the vignette begins.
    var vignetteMidpoint: Double = 50
    /// 0…100: how gradually it falls off.
    var vignetteFeather: Double = 50

    /// Detail. Nil is the default: a RAW decoder's own amount, none for any other still.
    /// 0…100: `CIRAWFilter.sharpnessAmount` (×1/100), else `CISharpenLuminance`.
    var sharpening: Double?
    /// 0…100: `CIRAWFilter.luminanceNoiseReductionAmount` (×1/100), else `CINoiseReduction`.
    var noiseReduction: Double?
    /// 0…100, RAWs whose decoder supports it: `colorNoiseReductionAmount`.
    var colorNoiseReduction: Double?
    /// 0…100, RAWs whose decoder supports it: `detailAmount` (0…3).
    var detail: Double?
    /// 0…100, RAWs whose decoder supports it: `moireReductionAmount`.
    var moireReduction: Double?

    /// Optics.
    /// `CIRAWFilter.isLensCorrectionEnabled`; nil is the decoder's default.
    var lensCorrection: Bool?

    /// Geometry, applied last and in this order: quarter turns, then flips, both in the
    /// displayed frame; then straighten; then crop.
    /// Clockwise quarter turns, 0…3.
    var quarterTurns: Int = 0
    /// Mirrors the turned photo left to right.
    var flipHorizontal = false
    /// Mirrors the turned photo top to bottom.
    var flipVertical = false
    /// Degrees clockwise, −45…45, through `CIStraightenFilter`, which scales the
    /// rotated photo to fill its frame so no empty corner shows.
    var straighten: Double = 0
    /// The kept part of the straightened frame; nil keeps all of it.
    var crop: EditCrop?

    /// Video.
    /// Seconds from the start of a video where its trimmed range begins; nil is its start.
    var trimStart: Double?
    /// Seconds from the start of a video where its trimmed range ends; nil is its end.
    var trimEnd: Double?

    static let neutral = EditRecipe()

    var isNeutral: Bool {
        self == .neutral
    }

    init(
        exposure: Double = 0,
        contrast: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        temperature: Double? = nil,
        tint: Double? = nil,
        vibrance: Double = 0,
        saturation: Double = 0,
        vignette: Double = 0,
        vignetteMidpoint: Double = 50,
        vignetteFeather: Double = 50,
        sharpening: Double? = nil,
        noiseReduction: Double? = nil,
        colorNoiseReduction: Double? = nil,
        detail: Double? = nil,
        moireReduction: Double? = nil,
        lensCorrection: Bool? = nil,
        quarterTurns: Int = 0,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false,
        straighten: Double = 0,
        crop: EditCrop? = nil,
        trimStart: Double? = nil,
        trimEnd: Double? = nil
    ) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.temperature = temperature
        self.tint = tint
        self.vibrance = vibrance
        self.saturation = saturation
        self.vignette = vignette
        self.vignetteMidpoint = vignetteMidpoint
        self.vignetteFeather = vignetteFeather
        self.sharpening = sharpening
        self.noiseReduction = noiseReduction
        self.colorNoiseReduction = colorNoiseReduction
        self.detail = detail
        self.moireReduction = moireReduction
        self.lensCorrection = lensCorrection
        self.quarterTurns = quarterTurns
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.straighten = straighten
        self.crop = crop
        self.trimStart = trimStart
        self.trimEnd = trimEnd
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        tint = try container.decodeIfPresent(Double.self, forKey: .tint)
        vibrance = try container.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        vignette = try container.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        vignetteMidpoint = try container.decodeIfPresent(Double.self, forKey: .vignetteMidpoint) ?? 50
        vignetteFeather = try container.decodeIfPresent(Double.self, forKey: .vignetteFeather) ?? 50
        sharpening = try container.decodeIfPresent(Double.self, forKey: .sharpening)
        noiseReduction = try container.decodeIfPresent(Double.self, forKey: .noiseReduction)
        colorNoiseReduction = try container.decodeIfPresent(Double.self, forKey: .colorNoiseReduction)
        detail = try container.decodeIfPresent(Double.self, forKey: .detail)
        moireReduction = try container.decodeIfPresent(Double.self, forKey: .moireReduction)
        lensCorrection = try container.decodeIfPresent(Bool.self, forKey: .lensCorrection)
        quarterTurns = try container.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0
        flipHorizontal = try container.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try container.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        straighten = try container.decodeIfPresent(Double.self, forKey: .straighten) ?? 0
        crop = try container.decodeIfPresent(EditCrop.self, forKey: .crop)
        trimStart = try container.decodeIfPresent(Double.self, forKey: .trimStart)
        trimEnd = try container.decodeIfPresent(Double.self, forKey: .trimEnd)
    }
}

/// The kept part of the straightened frame, in fractions of its width and height from
/// the top-left corner.
nonisolated struct EditCrop: Codable, Equatable, Hashable, Sendable {
    var left: Double
    var top: Double
    var width: Double
    var height: Double

    static let whole = EditCrop(left: 0, top: 0, width: 1, height: 1)
    /// The smallest a crop side may be, as a fraction of the frame.
    static let minimumSide = 0.02

    /// The same crop kept inside the frame and at least the minimum size.
    var clamped: EditCrop {
        let width = min(max(width, Self.minimumSide), 1)
        let height = min(max(height, Self.minimumSide), 1)
        return EditCrop(
            left: min(max(left, 0), 1 - width),
            top: min(max(top, 0), 1 - height),
            width: width,
            height: height
        )
    }

    /// A crop that keeps (all but rounding) the whole frame is no crop.
    var isWhole: Bool {
        abs(left) < 1e-4 && abs(top) < 1e-4 && abs(width - 1) < 1e-4 && abs(height - 1) < 1e-4
    }

    var right: Double {
        left + width
    }

    var bottom: Double {
        top + height
    }

    /// The crop's center, in the same fractions.
    var center: CGPoint {
        CGPoint(x: left + width / 2, y: top + height / 2)
    }

    /// The crop after the frame turns a quarter clockwise.
    var turnedClockwise: EditCrop {
        EditCrop(left: 1 - bottom, top: left, width: height, height: width)
    }

    /// The crop after the frame turns a quarter counterclockwise.
    var turnedCounterclockwise: EditCrop {
        EditCrop(left: top, top: 1 - right, width: height, height: width)
    }

    var mirroredHorizontally: EditCrop {
        EditCrop(left: 1 - right, top: top, width: width, height: height)
    }

    var mirroredVertically: EditCrop {
        EditCrop(left: left, top: 1 - bottom, width: width, height: height)
    }

    /// Width over height in fractions for a pixel ratio `pixelRatio` (width over height) in
    /// a frame of `frame` pixels.
    static func fractionRatio(pixelRatio: Double, frame: CGSize) -> Double {
        guard frame.width > 0 else { return pixelRatio }
        return pixelRatio * Double(frame.height / frame.width)
    }

    /// The crop moved by `delta` (fractions of the frame), kept inside it.
    func moved(by delta: CGSize) -> EditCrop {
        EditCrop(left: left + delta.width, top: top + delta.height, width: width, height: height).clamped
    }

    /// The crop with `handle` dragged by `delta` (fractions of the frame). The opposite
    /// corner or edge stays put; an edge handle keeps the crop centered across it. With a
    /// `fractionRatio` (width over height in fractions) the crop keeps that shape, following
    /// whichever side the drag changed more, and shrinks to fit when it would leave the frame.
    func resized(_ handle: CropHandle, by delta: CGSize, fractionRatio ratio: Double?) -> EditCrop {
        let horizontal = Self.dragged(left, right, edge: handle.horizontal, by: delta.width)
        let vertical = Self.dragged(top, bottom, edge: handle.vertical, by: delta.height)
        let free = EditCrop(
            left: horizontal.lower,
            top: vertical.lower,
            width: horizontal.upper - horizontal.lower,
            height: vertical.upper - vertical.lower
        )
        guard let ratio, ratio > 0 else {
            return free
        }
        // The anchor is the side that does not move, or the center across an edge handle.
        let anchorX = Self.anchor(left, right, edge: handle.horizontal)
        let anchorY = Self.anchor(top, bottom, edge: handle.vertical)
        var newWidth: Double = switch (handle.horizontal, handle.vertical) {
        case (0, _): free.height * ratio
        case (_, 0): free.width
        default: max(free.width, free.height * ratio)
        }
        newWidth = min(
            newWidth,
            Self.room(from: anchorX, edge: handle.horizontal),
            Self.room(from: anchorY, edge: handle.vertical) * ratio
        )
        newWidth = max(newWidth, Self.minimumSide * max(1, ratio))
        let newHeight = newWidth / ratio
        return EditCrop(
            left: Self.placed(from: anchorX, edge: handle.horizontal, extent: newWidth),
            top: Self.placed(from: anchorY, edge: handle.vertical, extent: newHeight),
            width: newWidth,
            height: newHeight
        ).clamped
    }

    /// The largest crop of `pixelRatio` (width over height, in pixels) inside a frame of
    /// `frame` pixels, centered on `center` and moved only as far as it must to stay in it.
    static func largest(pixelRatio: Double, frame: CGSize, around center: CGPoint) -> EditCrop {
        let ratio = fractionRatio(pixelRatio: pixelRatio, frame: frame)
        let width = ratio >= 1 ? 1 : ratio
        let height = ratio >= 1 ? 1 / ratio : 1
        return EditCrop(left: center.x - width / 2, top: center.y - height / 2, width: width, height: height).clamped
    }

    /// One axis of a free resize: the dragged side moves, inside the frame and never past
    /// the other side less the minimum.
    private static func dragged(
        _ lower: Double,
        _ upper: Double,
        edge: Int,
        by delta: Double
    ) -> (lower: Double, upper: Double) {
        switch edge {
        case -1: (min(max(lower + delta, 0), upper - minimumSide), upper)
        case 1: (lower, max(min(upper + delta, 1), lower + minimumSide))
        default: (lower, upper)
        }
    }

    private static func anchor(_ lower: Double, _ upper: Double, edge: Int) -> Double {
        switch edge {
        case -1: upper
        case 1: lower
        default: (lower + upper) / 2
        }
    }

    /// How far a crop anchored at `anchor` may extend on this axis inside the frame.
    private static func room(from anchor: Double, edge: Int) -> Double {
        switch edge {
        case -1: anchor
        case 1: 1 - anchor
        default: 2 * min(anchor, 1 - anchor)
        }
    }

    /// Where the crop starts on this axis for an extent laid out from its anchor.
    private static func placed(from anchor: Double, edge: Int, extent: Double) -> Double {
        switch edge {
        case -1: anchor - extent
        case 1: anchor
        default: anchor - extent / 2
        }
    }
}

nonisolated extension EditRecipe {
    /// The recipe with no crop: what the crop tool shows the whole frame of.
    var uncropped: EditRecipe {
        var recipe = self
        recipe.crop = nil
        return recipe
    }

    var hasGeometry: Bool {
        quarterTurns != 0 || flipHorizontal || flipVertical || straighten != 0 || crop != nil
    }

    /// The photo's frame — its oriented original turned by the recipe — before the crop.
    func frameSize(ofOriginal size: CGSize) -> CGSize {
        quarterTurns.isMultiple(of: 2) ? size : CGSize(width: size.height, height: size.width)
    }

    /// The edited photo's size in pixels, for an oriented original of `size`.
    func outputSize(ofOriginal size: CGSize) -> CGSize {
        let frame = frameSize(ofOriginal: size)
        let crop = crop ?? .whole
        return CGSize(width: (frame.width * crop.width).rounded(), height: (frame.height * crop.height).rounded())
    }

    /// The fraction of the frame's long edge that the crop's long edge spans, in pixels:
    /// how much larger than the output the frame must be developed for the output to
    /// reach a given size.
    func cropLongEdgeFraction(ofOriginal size: CGSize) -> Double {
        let frame = frameSize(ofOriginal: size)
        let output = outputSize(ofOriginal: size)
        let frameLong = max(frame.width, frame.height)
        guard frameLong > 0 else { return 1 }
        return min(1, max(output.width, output.height) / frameLong)
    }

    /// The recipe after the displayed photo turns a quarter: the crop turns with it, and
    /// a turn applied over exactly one flip moves the other way, because a mirror reverses
    /// the sense of a rotation.
    func turned(clockwise: Bool) -> EditRecipe {
        var recipe = self
        let oneFlip = flipHorizontal != flipVertical
        let step = (clockwise ? 1 : -1) * (oneFlip ? -1 : 1)
        recipe.quarterTurns = ((quarterTurns + step) % 4 + 4) % 4
        recipe.crop = crop.map { clockwise ? $0.turnedClockwise : $0.turnedCounterclockwise }
        return recipe
    }

    /// The recipe after the displayed photo is mirrored. The crop mirrors with it, and the
    /// straighten angle reverses, because a mirror reverses the sense of a rotation.
    func flipped(horizontally: Bool) -> EditRecipe {
        var recipe = self
        if horizontally {
            recipe.flipHorizontal.toggle()
            recipe.crop = crop?.mirroredHorizontally
        } else {
            recipe.flipVertical.toggle()
            recipe.crop = crop?.mirroredVertically
        }
        recipe.straighten = straighten == 0 ? 0 : -straighten
        return recipe
    }
}

/// One of the crop frame's eight handles: which edge it moves on each axis, −1 for the
/// left or top, 1 for the right or bottom, 0 for neither.
nonisolated enum CropHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var horizontal: Int {
        switch self {
        case .topLeft, .bottomLeft, .left: -1
        case .topRight, .bottomRight, .right: 1
        case .top, .bottom: 0
        }
    }

    var vertical: Int {
        switch self {
        case .topLeft, .top, .topRight: -1
        case .bottomLeft, .bottom, .bottomRight: 1
        case .left, .right: 0
        }
    }
}

/// The crop tool's aspect choices, Lightroom desktop's common set. A ratio is long side
/// to short side; which way it stands follows the crop, and Rotate Aspect turns it.
nonisolated enum CropAspect: String, CaseIterable, Identifiable, Sendable {
    case original
    case free
    case square
    case fourByFive
    case fiveBySeven
    case twoByThree
    case threeByFour
    case sixteenByNine

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .original: "Original"
        case .free: "Custom"
        case .square: "1 × 1"
        case .fourByFive: "4 × 5"
        case .fiveBySeven: "5 × 7"
        case .twoByThree: "2 × 3"
        case .threeByFour: "4 × 3"
        case .sixteenByNine: "16 × 9"
        }
    }

    /// Long over short side, or nil for a free crop. Original is the frame's own ratio.
    func longOverShort(frame: CGSize) -> Double? {
        switch self {
        case .free: nil
        case .original:
            min(frame.width, frame.height) > 0
                ? Double(max(frame.width, frame.height) / min(frame.width, frame.height)) : nil
        case .square: 1
        case .fourByFive: 5.0 / 4
        case .fiveBySeven: 7.0 / 5
        case .twoByThree: 3.0 / 2
        case .threeByFour: 4.0 / 3
        case .sixteenByNine: 16.0 / 9
        }
    }
}

/// What the open photo says about itself, which the panel needs to show the Color
/// section: whether it is a RAW, and for a RAW its as-shot white balance — the values a
/// recipe's nil `temperature` and `tint` stand for. Known once the photo is open.
nonisolated struct EditPhotoFacts: Equatable, Sendable {
    let isRAW: Bool
    let asShotTemperature: Double?
    let asShotTint: Double?
    /// For a RAW, the Detail controls its decoder supports, each with the decoder's own
    /// amount in slider units (0…100): what a nil recipe value stands for.
    var rawDetail: [EditControl: Double] = [:]
    /// For a RAW with a lens profile, whether its decoder corrects the lens by default; nil
    /// when the photo cannot be corrected.
    var lensCorrectionDefault: Bool?
    /// The straighten, in degrees clockwise, that levels the upright original by the
    /// camera's own gravity reading at capture, as MediaMetadata reports it; nil when the
    /// file carries none it can trust (a front camera, a camera pointed up or down, any
    /// camera without a level sensor). Level ▸ Camera is available only with one.
    var cameraLevel: Double?

    static let still = EditPhotoFacts(isRAW: false, asShotTemperature: nil, asShotTint: nil)
}

/// What opening a photo for editing reports, all from the one decode its edits render
/// from: the decoder's facts, and the original's upright full-resolution size. The size is
/// the decoder's, never the catalog's: a HEIF rotated by its `irot` property can be
/// cataloged with its stored, unrotated size, and geometry built on that crops the wrong
/// shape.
nonisolated struct OpenedEditPhoto: Equatable, Sendable {
    let facts: EditPhotoFacts
    let pixelSize: CGSize
}

/// A photo or video with its saved edit, as a hand-off (ADR 0037) or an export (ADR 0038)
/// writes it: everything either needs to choose and produce the file.
nonisolated struct EditedMediaItem: Equatable, Sendable {
    let id: MediaAssetID
    let isVideo: Bool
    /// The saved edit; neutral when it was never edited.
    let recipe: EditRecipe
    let sourceSize: Int64?
}

extension EditedMediaItem {
    /// The item as its catalog row describes it. A target with no row (gone since it was
    /// chosen) is its path as it is, unedited, which is what Finder would hand over.
    nonisolated init(id: MediaAssetID, detail: MediaTileDetail?) {
        self.init(
            id: id,
            isVideo: detail?.bestKind == .video,
            recipe: detail?.editRecipe ?? .neutral,
            sourceSize: detail?.byteSize
        )
    }
}

/// A recipe as the catalog holds it: the values and the revision they were saved as.
/// Every save increments the revision, so a render can say which recipe it applied and
/// a result rendered from an older recipe is refused (ADR 0036).
nonisolated struct StoredEditRecipe: Equatable, Hashable, Sendable {
    let recipe: EditRecipe
    let revision: Int64
}

/// What saving a recipe did: whether the photo exists, the recipe it replaced, and the
/// recipe now saved — nil when the save changed nothing. `sourceSize` and
/// `sourceMTimeSeconds` are the catalog's facts about the original at the moment of the
/// save; the render made for the save carries them back, so products rendered from a
/// file that has since changed are refused (ADR 0036).
nonisolated struct EditRecipeMutationResult: Equatable, Sendable {
    let exists: Bool
    let previous: StoredEditRecipe?
    let saved: StoredEditRecipe?
    var sourceSize: Int64?
    var sourceMTimeSeconds: Int?
    /// The asset is a video: its thumbnail and poster do not depend on its edit (a trim), so
    /// the save already marked them current and nothing is rendered for it.
    var isVideo = false
}

/// A thumbnail and preview rendered from one saved recipe, staged for the store to
/// promote only while that recipe is still current (ADR 0036).
nonisolated struct RenderedEditProducts: Equatable, Sendable {
    let id: MediaAssetID
    let revision: Int64
    let sourceSize: Int64?
    let sourceMTimeSeconds: Int?
    let thumbnail: StagedDerivedImage
    let preview: StagedDerivedImage
}

/// The panel's sections, in Lightroom desktop's order (ADR 0036).
nonisolated enum EditSection: String, CaseIterable, Identifiable, Sendable {
    /// The crop tool, above the sections as in Lightroom desktop: crop, straighten,
    /// quarter turns and flips.
    case crop
    case light
    case color
    case effects
    case detail
    case optics

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .crop: "Crop"
        case .light: "Light"
        case .color: "Color"
        case .effects: "Effects"
        case .detail: "Detail"
        case .optics: "Optics"
        }
    }

    /// The SF Symbol beside the heading, as Photos marks each of its Adjust sections.
    var symbol: String {
        switch self {
        case .crop: "crop"
        case .light: "sun.max"
        case .color: "paintpalette"
        case .effects: "circle.dashed"
        case .detail: "triangle.lefthalf.filled"
        case .optics: "camera.aperture"
        }
    }

    var controls: [EditControl] {
        EditControl.allCases.filter { $0.section == self }
    }

    /// Undo title of the section's Reset.
    var resetActionName: String {
        "Reset \(title)"
    }

    /// Whether this photo has anything to adjust here: Optics only for a RAW with a lens
    /// profile, Detail for any still whose decoder offers a Detail control.
    func isAvailable(_ facts: EditPhotoFacts) -> Bool {
        switch self {
        case .optics: facts.lensCorrectionDefault != nil
        default: controls.isEmpty || controls.contains { $0.isAvailable(facts) }
        }
    }

    /// `recipe` with every control of this section at neutral (white balance as shot).
    func reset(_ recipe: EditRecipe) -> EditRecipe {
        var reset = recipe
        switch self {
        case .crop:
            reset.quarterTurns = 0
            reset.flipHorizontal = false
            reset.flipVertical = false
            reset.straighten = 0
            reset.crop = nil
        case .light:
            reset.exposure = 0
            reset.contrast = 0
            reset.highlights = 0
            reset.shadows = 0
        case .color:
            reset.temperature = nil
            reset.tint = nil
            reset.vibrance = 0
            reset.saturation = 0
        case .effects:
            reset.vignette = 0
            reset.vignetteMidpoint = 50
            reset.vignetteFeather = 50
        case .detail:
            reset.sharpening = nil
            reset.noiseReduction = nil
            reset.colorNoiseReduction = nil
            reset.detail = nil
            reset.moireReduction = nil
        case .optics:
            reset.lensCorrection = nil
        }
        return reset
    }

    func isNeutral(in recipe: EditRecipe) -> Bool {
        reset(recipe) == recipe
    }
}

/// Every control the panel offers, in panel order. A control moves a slider through a
/// position; for most the position is the recipe value itself. A RAW's temperature
/// slider moves evenly in mireds (one million over kelvin), the way white balance is
/// perceived, so the common 3000–8000 K span is not squeezed into a fifth of its width.
nonisolated enum EditControl: String, CaseIterable, Identifiable, Sendable {
    case straighten
    case exposure
    case contrast
    case highlights
    case shadows
    case temperature
    case tint
    case vibrance
    case saturation
    case vignette
    case vignetteMidpoint
    case vignetteFeather
    case sharpening
    case noiseReduction
    case colorNoiseReduction
    case detail
    case moireReduction

    static let rawTemperatureRange: ClosedRange<Double> = 2000 ... 50000
    static let rawTintRange: ClosedRange<Double> = -150 ... 150

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .straighten: "Straighten"
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .temperature: "Temperature"
        case .tint: "Tint"
        case .vibrance: "Vibrance"
        case .saturation: "Saturation"
        case .vignette: "Vignette"
        case .vignetteMidpoint: "Midpoint"
        case .vignetteFeather: "Feather"
        case .sharpening: "Sharpening"
        case .noiseReduction: "Noise Reduction"
        case .colorNoiseReduction: "Color Noise"
        case .detail: "Detail"
        case .moireReduction: "Moiré"
        }
    }

    var section: EditSection {
        switch self {
        case .straighten: .crop
        case .exposure, .contrast, .highlights, .shadows: .light
        case .temperature, .tint, .vibrance, .saturation: .color
        case .vignette, .vignetteMidpoint, .vignetteFeather: .effects
        case .sharpening, .noiseReduction, .colorNoiseReduction, .detail, .moireReduction: .detail
        }
    }

    /// Whether the photo offers this control. A RAW offers the Detail controls its
    /// decoder supports; any other still offers Sharpening and Noise Reduction.
    func isAvailable(_ facts: EditPhotoFacts) -> Bool {
        switch self {
        case .sharpening, .noiseReduction:
            !facts.isRAW || facts.rawDetail[self] != nil
        case .colorNoiseReduction, .detail, .moireReduction:
            facts.isRAW && facts.rawDetail[self] != nil
        default:
            true
        }
    }

    /// The slider's domain for a photo with `facts`.
    func sliderRange(_ facts: EditPhotoFacts) -> ClosedRange<Double> {
        switch self {
        case .straighten: -45 ... 45
        case .exposure: -4 ... 4
        case .contrast, .highlights, .shadows, .vibrance, .saturation, .vignette: -100 ... 100
        case .vignetteMidpoint, .vignetteFeather, .sharpening, .noiseReduction,
             .colorNoiseReduction, .detail, .moireReduction: 0 ... 100
        case .temperature: facts.isRAW ? 0 ... 1 : -100 ... 100
        case .tint: facts.isRAW ? Self.rawTintRange : -100 ... 100
        }
    }

    /// Where the slider sits for `recipe`.
    func sliderValue(in recipe: EditRecipe, facts: EditPhotoFacts) -> Double {
        switch self {
        case .straighten: recipe.straighten
        case .exposure: recipe.exposure
        case .contrast: recipe.contrast
        case .highlights: recipe.highlights
        case .shadows: recipe.shadows
        case .vibrance: recipe.vibrance
        case .saturation: recipe.saturation
        case .vignette: recipe.vignette
        case .vignetteMidpoint: recipe.vignetteMidpoint
        case .vignetteFeather: recipe.vignetteFeather
        case .sharpening: recipe.sharpening ?? facts.rawDetail[self] ?? 0
        case .noiseReduction: recipe.noiseReduction ?? facts.rawDetail[self] ?? 0
        case .colorNoiseReduction: recipe.colorNoiseReduction ?? facts.rawDetail[self] ?? 0
        case .detail: recipe.detail ?? facts.rawDetail[self] ?? 0
        case .moireReduction: recipe.moireReduction ?? facts.rawDetail[self] ?? 0
        case .temperature:
            facts.isRAW
                ? Self.position(ofKelvin: recipe.temperature ?? facts.asShotTemperature ?? 5500)
                : recipe.temperature ?? 0
        case .tint:
            recipe.tint ?? (facts.isRAW ? facts.asShotTint ?? 0 : 0)
        }
    }

    /// `recipe` with this one control back at its neutral value: double-clicking its name
    /// in the panel (Lightroom's idiom). A Detail amount or a white balance returns to the
    /// photo's own (`nil`), as its section's Reset does.
    func reset(_ recipe: EditRecipe) -> EditRecipe {
        var reset = recipe
        let neutral = EditRecipe.neutral
        switch self {
        case .straighten: reset.straighten = neutral.straighten
        case .exposure: reset.exposure = neutral.exposure
        case .contrast: reset.contrast = neutral.contrast
        case .highlights: reset.highlights = neutral.highlights
        case .shadows: reset.shadows = neutral.shadows
        case .temperature: reset.temperature = neutral.temperature
        case .tint: reset.tint = neutral.tint
        case .vibrance: reset.vibrance = neutral.vibrance
        case .saturation: reset.saturation = neutral.saturation
        case .vignette: reset.vignette = neutral.vignette
        case .vignetteMidpoint: reset.vignetteMidpoint = neutral.vignetteMidpoint
        case .vignetteFeather: reset.vignetteFeather = neutral.vignetteFeather
        case .sharpening: reset.sharpening = neutral.sharpening
        case .noiseReduction: reset.noiseReduction = neutral.noiseReduction
        case .colorNoiseReduction: reset.colorNoiseReduction = neutral.colorNoiseReduction
        case .detail: reset.detail = neutral.detail
        case .moireReduction: reset.moireReduction = neutral.moireReduction
        }
        return reset
    }

    /// How far one press of Increase or Decrease Adjustment (= and −) moves the slider:
    /// a twentieth of a stop, a degree, fifty kelvin near daylight, or five units.
    func keyboardStep(_ facts: EditPhotoFacts) -> Double {
        switch self {
        case .exposure: 0.05
        case .straighten: 1
        case .temperature where facts.isRAW: 0.005
        default: 5
        }
    }

    /// Periodic labels for a slider whose scale is not linear (Sliders, macOS): a RAW's
    /// temperature, even in mireds, marked at 2500, 4000 and 10000 K — spaced about evenly
    /// along the track (21, 52 and 83 percent), where 5500 K would crowd 10000 K. Positions
    /// are fractions of the slider's travel.
    func scaleLabels(_ facts: EditPhotoFacts) -> [(position: Double, text: String)] {
        guard self == .temperature, facts.isRAW else { return [] }
        return [2500.0, 4000, 10000].map { (Self.position(ofKelvin: $0), "\(Int($0))") }
    }

    /// `recipe` with this control moved to slider `position`, snapped to the control's
    /// step and clamped to its range. A still's white balance at zero is stored as shot.
    func applying(_ position: Double, to recipe: EditRecipe, facts: EditPhotoFacts) -> EditRecipe {
        var recipe = recipe
        let range = sliderRange(facts)
        let clamped = min(max(position, range.lowerBound), range.upperBound)
        switch self {
        case .straighten: recipe.straighten = Self.snapped(clamped, step: 0.1)
        case .exposure: recipe.exposure = Self.snapped(clamped, step: 0.05)
        case .contrast: recipe.contrast = clamped.rounded()
        case .highlights: recipe.highlights = clamped.rounded()
        case .shadows: recipe.shadows = clamped.rounded()
        case .vibrance: recipe.vibrance = clamped.rounded()
        case .saturation: recipe.saturation = clamped.rounded()
        case .vignette: recipe.vignette = clamped.rounded()
        case .vignetteMidpoint: recipe.vignetteMidpoint = clamped.rounded()
        case .vignetteFeather: recipe.vignetteFeather = clamped.rounded()
        case .sharpening: recipe.sharpening = clamped.rounded()
        case .noiseReduction: recipe.noiseReduction = clamped.rounded()
        case .colorNoiseReduction: recipe.colorNoiseReduction = clamped.rounded()
        case .detail: recipe.detail = clamped.rounded()
        case .moireReduction: recipe.moireReduction = clamped.rounded()
        case .temperature:
            if facts.isRAW {
                recipe.temperature = Self.snapped(Self.kelvin(atPosition: clamped), step: 50)
            } else {
                let value = clamped.rounded()
                recipe.temperature = value == 0 ? nil : value
            }
        case .tint:
            let value = clamped.rounded()
            recipe.tint = !facts.isRAW && value == 0 ? nil : value
        }
        return recipe
    }

    /// The value as the panel shows it: stops to two decimals, kelvin with its unit, the
    /// rest as whole numbers with an explicit sign so a positive value never reads as
    /// neutral.
    func formatted(_ recipe: EditRecipe, facts: EditPhotoFacts) -> String {
        switch self {
        case .exposure:
            return recipe.exposure == 0 ? "0.00" : String(format: "%+.2f", recipe.exposure)
        case .straighten:
            return recipe.straighten == 0 ? "0.0°" : String(format: "%+.1f°", recipe.straighten)
        case .temperature where facts.isRAW:
            let kelvin = recipe.temperature ?? facts.asShotTemperature ?? 0
            return "\(Int(kelvin.rounded())) K"
        case .vignetteMidpoint, .vignetteFeather, .sharpening, .noiseReduction,
             .colorNoiseReduction, .detail, .moireReduction:
            // Amounts with no direction carry no sign.
            return "\(Int(sliderValue(in: recipe, facts: facts).rounded()))"
        default:
            let rounded = Int(sliderValue(in: recipe, facts: facts).rounded())
            return rounded == 0 ? "0" : String(format: "%+d", rounded)
        }
    }

    /// The slider position for a value typed into the control's field (F-15 in
    /// `hig-validation.md`), or nil when the text is not a number. The text is what the
    /// panel shows, so a sign, a degree mark and a kelvin unit are accepted. A RAW's
    /// temperature is typed in kelvin. The result is not clamped: `applying` clamps it.
    func position(fromEntered text: String, facts: EditPhotoFacts) -> Double? {
        let trimmed = text
            .replacingOccurrences(of: "°", with: "")
            .replacingOccurrences(of: "K", with: "")
            .replacingOccurrences(of: "k", with: "")
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .trimmingCharacters(in: .whitespaces)
        guard let number = Double(trimmed), number.isFinite else {
            return nil
        }
        if self == .temperature, facts.isRAW {
            return Self.position(ofKelvin: number)
        }
        return number
    }

    /// Slider position 0…1 of `kelvin`: 0 is 2000 K, 1 is 50000 K, linear in mireds.
    static func position(ofKelvin kelvin: Double) -> Double {
        let clamped = min(max(kelvin, rawTemperatureRange.lowerBound), rawTemperatureRange.upperBound)
        return (lowKelvinMired - 1_000_000 / clamped) / (lowKelvinMired - highKelvinMired)
    }

    static func kelvin(atPosition position: Double) -> Double {
        1_000_000 / (lowKelvinMired - position * (lowKelvinMired - highKelvinMired))
    }

    private static let lowKelvinMired = 1_000_000 / rawTemperatureRange.lowerBound
    private static let highKelvinMired = 1_000_000 / rawTemperatureRange.upperBound

    private static func snapped(_ value: Double, step: Double) -> Double {
        (value / step).rounded() * step
    }
}
