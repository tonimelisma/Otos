import Foundation
import UniformTypeIdentifiers

/// The file File ▸ Export… writes for a photo (ADR 0038). JPEG and HEIC are the photo as
/// Otos shows it, rendered with its edit; Original is the original file, byte for byte.
nonisolated enum ExportFormat: String, CaseIterable, Equatable, Sendable {
    case jpeg
    case heic
    case original

    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .original: "Original"
        }
    }

    /// The rendered file's type and extension; nil for Original, which keeps the original's.
    var renderedType: (type: UTType, fileExtension: String)? {
        switch self {
        case .jpeg: (.jpeg, "jpg")
        case .heic: (.heic, "heic")
        case .original: nil
        }
    }
}

/// The export sheet's choices, remembered across launches (`ExportSettingsStore`).
nonisolated struct ExportSettings: Equatable, Sendable {
    static let formatKey = "export.format"
    static let limitsSizeKey = "export.limitsSize"
    static let longEdgeKey = "export.longEdge"
    static let qualityKey = "export.quality"
    static let removesLocationKey = "export.removesLocation"
    static let destinationKey = "export.destination"

    /// The long edges the size field accepts, in pixels.
    static let longEdgeRange = 64 ... 32768

    var format: ExportFormat
    /// Whether a rendered photo is scaled down to `longEdge`; never up.
    var limitsSize: Bool
    var longEdge: Int
    /// JPEG and HEIC compression quality, 0 to 1.
    var quality: Double
    var removesLocation: Bool
    /// The folder exports are written to; nil until one is chosen.
    var destination: URL?

    static let `default` = ExportSettings(
        format: .jpeg,
        limitsSize: false,
        longEdge: 2048,
        quality: 0.9,
        removesLocation: false,
        destination: nil
    )

    /// The long edge a rendered photo is limited to, or nil for full size.
    var outputLongEdge: Int? {
        limitsSize ? longEdge : nil
    }

    /// Size, quality and location removal shape a rendered file; an Original is the file.
    var shapesRenderedFile: Bool {
        format != .original
    }

    /// These settings with the long edge and quality brought into range.
    var clamped: ExportSettings {
        var settings = self
        settings.longEdge = min(max(longEdge, Self.longEdgeRange.lowerBound), Self.longEdgeRange.upperBound)
        settings.quality = min(max(quality, 0), 1)
        return settings
    }
}

/// Typed read and write owner for the export settings, backed by the view model's
/// injected `PreferenceStore` (ADR 0020).
nonisolated enum ExportSettingsStore {
    static func load(defaults: any PreferenceStore) -> ExportSettings {
        let fallback = ExportSettings.default
        return ExportSettings(
            format: defaults.string(forKey: ExportSettings.formatKey).flatMap(ExportFormat.init(rawValue:))
                ?? fallback.format,
            limitsSize: defaults.object(forKey: ExportSettings.limitsSizeKey) as? Bool ?? fallback.limitsSize,
            longEdge: defaults.object(forKey: ExportSettings.longEdgeKey) as? Int ?? fallback.longEdge,
            quality: defaults.object(forKey: ExportSettings.qualityKey) as? Double ?? fallback.quality,
            removesLocation: defaults.object(forKey: ExportSettings.removesLocationKey) as? Bool
                ?? fallback.removesLocation,
            destination: defaults.string(forKey: ExportSettings.destinationKey)
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ).clamped
    }

    static func save(_ settings: ExportSettings, defaults: any PreferenceStore) {
        defaults.set(settings.format.rawValue, forKey: ExportSettings.formatKey)
        defaults.set(settings.limitsSize, forKey: ExportSettings.limitsSizeKey)
        defaults.set(settings.longEdge, forKey: ExportSettings.longEdgeKey)
        defaults.set(settings.quality, forKey: ExportSettings.qualityKey)
        defaults.set(settings.removesLocation, forKey: ExportSettings.removesLocationKey)
        if let destination = settings.destination {
            defaults.set(destination.path(percentEncoded: false), forKey: ExportSettings.destinationKey)
        } else {
            defaults.removeObject(forKey: ExportSettings.destinationKey)
        }
    }
}
