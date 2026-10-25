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
        saturation: Double = 0
    ) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.temperature = temperature
        self.tint = tint
        self.vibrance = vibrance
        self.saturation = saturation
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
    }
}

/// What the open photo says about itself, which the panel needs to show the Color
/// section: whether it is a RAW, and for a RAW its as-shot white balance — the values a
/// recipe's nil `temperature` and `tint` stand for. Known once the photo is open.
nonisolated struct EditPhotoFacts: Equatable, Sendable {
    let isRAW: Bool
    let asShotTemperature: Double?
    let asShotTint: Double?

    static let still = EditPhotoFacts(isRAW: false, asShotTemperature: nil, asShotTint: nil)
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

/// The panel's sections, in Lightroom desktop's order (plan 0108).
nonisolated enum EditSection: String, CaseIterable, Identifiable, Sendable {
    case light
    case color

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .light: "Light"
        case .color: "Color"
        }
    }

    var controls: [EditControl] {
        EditControl.allCases.filter { $0.section == self }
    }

    /// Undo title of the section's Reset.
    var resetActionName: String {
        "Reset \(title)"
    }

    /// `recipe` with every control of this section at neutral (white balance as shot).
    func reset(_ recipe: EditRecipe) -> EditRecipe {
        var reset = recipe
        switch self {
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
    case exposure
    case contrast
    case highlights
    case shadows
    case temperature
    case tint
    case vibrance
    case saturation

    static let rawTemperatureRange: ClosedRange<Double> = 2000 ... 50000
    static let rawTintRange: ClosedRange<Double> = -150 ... 150

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .temperature: "Temperature"
        case .tint: "Tint"
        case .vibrance: "Vibrance"
        case .saturation: "Saturation"
        }
    }

    var section: EditSection {
        switch self {
        case .exposure, .contrast, .highlights, .shadows: .light
        case .temperature, .tint, .vibrance, .saturation: .color
        }
    }

    /// The slider's domain for a photo with `facts`.
    func sliderRange(_ facts: EditPhotoFacts) -> ClosedRange<Double> {
        switch self {
        case .exposure: -4 ... 4
        case .highlights: -100 ... 0
        case .contrast, .shadows, .vibrance, .saturation: -100 ... 100
        case .temperature: facts.isRAW ? 0 ... 1 : -100 ... 100
        case .tint: facts.isRAW ? Self.rawTintRange : -100 ... 100
        }
    }

    /// Where the slider sits for `recipe`.
    func sliderValue(in recipe: EditRecipe, facts: EditPhotoFacts) -> Double {
        switch self {
        case .exposure: recipe.exposure
        case .contrast: recipe.contrast
        case .highlights: recipe.highlights
        case .shadows: recipe.shadows
        case .vibrance: recipe.vibrance
        case .saturation: recipe.saturation
        case .temperature:
            facts.isRAW
                ? Self.position(ofKelvin: recipe.temperature ?? facts.asShotTemperature ?? 5500)
                : recipe.temperature ?? 0
        case .tint:
            recipe.tint ?? (facts.isRAW ? facts.asShotTint ?? 0 : 0)
        }
    }

    /// `recipe` with this control moved to slider `position`, snapped to the control's
    /// step and clamped to its range. A still's white balance at zero is stored as shot.
    func applying(_ position: Double, to recipe: EditRecipe, facts: EditPhotoFacts) -> EditRecipe {
        var recipe = recipe
        let range = sliderRange(facts)
        let clamped = min(max(position, range.lowerBound), range.upperBound)
        switch self {
        case .exposure: recipe.exposure = Self.snapped(clamped, step: 0.05)
        case .contrast: recipe.contrast = clamped.rounded()
        case .highlights: recipe.highlights = clamped.rounded()
        case .shadows: recipe.shadows = clamped.rounded()
        case .vibrance: recipe.vibrance = clamped.rounded()
        case .saturation: recipe.saturation = clamped.rounded()
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
        case .temperature where facts.isRAW:
            let kelvin = recipe.temperature ?? facts.asShotTemperature ?? 0
            return "\(Int(kelvin.rounded())) K"
        default:
            let rounded = Int(sliderValue(in: recipe, facts: facts).rounded())
            return rounded == 0 ? "0" : String(format: "%+d", rounded)
        }
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
