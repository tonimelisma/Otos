import Foundation

/// One photo's current edit (plan 0108 decision 1): the values of every control the
/// edit panel offers, applied on top of the original when it is rendered. The original
/// is never changed (decision 2). A value at its neutral point changes nothing, and a
/// recipe whose every value is neutral renders exactly as the unedited photo.
///
/// Stored as JSON in `media_asset.edit_recipe_json` (ADR 0036), so adding a control is a
/// new optional field rather than a schema change; a field a recipe does not carry
/// decodes as neutral.
nonisolated struct EditRecipe: Codable, Equatable, Hashable, Sendable {
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

    static let neutral = EditRecipe()

    var isNeutral: Bool {
        self == .neutral
    }

    init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
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

/// The Light section's controls, in panel order, with their ranges.
nonisolated enum LightControl: String, CaseIterable, Identifiable, Sendable {
    case exposure
    case contrast
    case highlights
    case shadows

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .exposure: -4 ... 4
        case .contrast: -100 ... 100
        case .highlights: -100 ... 0
        case .shadows: -100 ... 100
        }
    }

    var step: Double {
        self == .exposure ? 0.05 : 1
    }

    /// The value as the panel shows it: stops to two decimals, the rest as whole numbers,
    /// with an explicit sign so a positive value never reads as neutral.
    func formatted(_ value: Double) -> String {
        if self == .exposure {
            return value == 0 ? "0.00" : String(format: "%+.2f", value)
        }
        let rounded = Int(value.rounded())
        return rounded == 0 ? "0" : String(format: "%+d", rounded)
    }

    func value(in recipe: EditRecipe) -> Double {
        switch self {
        case .exposure: recipe.exposure
        case .contrast: recipe.contrast
        case .highlights: recipe.highlights
        case .shadows: recipe.shadows
        }
    }

    func applying(_ value: Double, to recipe: EditRecipe) -> EditRecipe {
        var recipe = recipe
        let stepped = (value / step).rounded() * step
        let clamped = min(max(stepped, range.lowerBound), range.upperBound)
        switch self {
        case .exposure: recipe.exposure = clamped
        case .contrast: recipe.contrast = clamped
        case .highlights: recipe.highlights = clamped
        case .shadows: recipe.shadows = clamped
        }
        return recipe
    }
}
