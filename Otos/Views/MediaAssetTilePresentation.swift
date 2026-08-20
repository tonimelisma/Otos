import AppKit
import CoreGraphics
import Foundation

// Pure tile presentation guide
//
// These helpers keep kind-badge policy, placeholder glyph selection (loading vs
// broken-media slash icons), thumbnail face geometry, and thumbnail-load policy
// independent from reusable AppKit view state. The AppKit tile calls into this
// file, and tests assert these value-level decisions directly. Lower-right badges
// appear only after a real thumbnail has painted; broken/unavailable tiles never
// show a corner badge. Accessibility is derived from detail + badge content so
// loading placeholders keep kind labels for VoiceOver.

struct LoadedTile {
    let image: CGImage?
    let pixelSize: CGSize?
}

/// Lower-right shaded badge content for a painted tile face.
nonisolated enum TileBadgeContent: Equatable {
    case none
    case durationText(String)
    case filmIcon
    case rawLabel
}

nonisolated enum MediaAssetTileLayout {
    static let contentCornerRadius: CGFloat = 4
    static let badgeCornerRadius: CGFloat = 3
    static let badgeHorizontalPadding: CGFloat = 5
    static let badgeHeight: CGFloat = 20
    static let badgeMinWidth: CGFloat = 22
    static let badgeTextY: CGFloat = 3
    static let badgeTextHeight: CGFloat = 14
    static let filmIconSize: CGFloat = 13
    static let placeholderIconAlpha: CGFloat = 0.35
    static let placeholderIconMinSide: CGFloat = 16
    static let placeholderIconMaxSide: CGFloat = 40
    static let rawLabel = "RAW"

    /// A quarter of the shorter content dimension, clamped to a legible range — big
    /// enough to read as a deliberate kind indicator on a small tile, small enough to
    /// stay a quiet placeholder rather than a dominant glyph.
    static func placeholderIconSide(contentBounds: CGRect) -> CGFloat {
        let side = min(contentBounds.width, contentBounds.height) / 4
        return min(max(side, placeholderIconMinSide), placeholderIconMaxSide)
    }

    static func placeholderIconFrame(contentBounds: CGRect) -> CGRect {
        let side = placeholderIconSide(contentBounds: contentBounds)
        return CGRect(
            x: (contentBounds.width - side) / 2,
            y: (contentBounds.height - side) / 2,
            width: side,
            height: side
        )
    }

    static func kindBadgeFrame(
        contentBounds: CGRect,
        badgeWidth: CGFloat,
        badgeHeight: CGFloat = badgeHeight
    ) -> CGRect? {
        guard contentBounds.width >= badgeWidth,
              contentBounds.height >= badgeHeight
        else {
            return nil
        }
        return CGRect(
            x: contentBounds.width - badgeWidth,
            y: contentBounds.height - badgeHeight,
            width: badgeWidth,
            height: badgeHeight
        )
    }

    static func kindBadgeWidth(textWidth: CGFloat?) -> CGFloat {
        guard let textWidth else {
            return badgeMinWidth
        }
        return max(
            badgeMinWidth,
            ceil(textWidth) + badgeHorizontalPadding * 2
        )
    }

    /// Centers the measured text within the badge. When the min-width clamp wins,
    /// the label is still centered on the actual text width rather than inset by
    /// the fixed padding alone.
    static func kindBadgeLabelFrame(badgeWidth: CGFloat, textWidth: CGFloat) -> CGRect {
        let clampedTextWidth = min(max(ceil(textWidth), 0), badgeWidth)
        let x = max((badgeWidth - clampedTextWidth) / 2, 0)
        return CGRect(
            x: x,
            y: badgeTextY,
            width: clampedTextWidth,
            height: badgeTextHeight
        )
    }
}

nonisolated enum MediaAssetTilePresentation {
    static func isVideo(_ detail: MediaTileDetail) -> Bool {
        detail.bestKind == .video
    }

    /// Formats known finite video duration for the lower-right badge.
    static func videoBadgeText(_ detail: MediaTileDetail) -> String? {
        guard detail.bestKind == .video,
              let durationSeconds = detail.durationSeconds,
              durationSeconds.isFinite
        else {
            return nil
        }
        let wholeSeconds = max(0, Int64(durationSeconds.rounded(.down)))
        let duration = Duration.seconds(wholeSeconds)
        if wholeSeconds >= 3600 {
            return duration.formatted(.time(pattern: .hourMinuteSecond))
        }
        return duration.formatted(.time(pattern: .minuteSecond))
    }

    /// Lower-right badge policy. Broken / not-yet-enriched tiles never get a
    /// badge; painted video shows duration or a film-icon fallback; painted raw
    /// shows `RAW`. `thumbnailUnavailable` is an explicit gate so a future paint
    /// of non-thumbnail content cannot resurrect badges on broken tiles.
    static func badgeContent(
        detail: MediaTileDetail,
        thumbnailPainted: Bool,
        formattedDuration: String? = nil
    ) -> TileBadgeContent {
        guard thumbnailPainted, !detail.thumbnailUnavailable else {
            return .none
        }
        switch detail.bestKind {
        case .video:
            if let text = formattedDuration ?? videoBadgeText(detail) {
                return .durationText(text)
            }
            return .filmIcon
        case .raw:
            return .rawLabel
        case .image, .none:
            return .none
        }
    }

    /// Accessibility for the whole tile: filename first — it is the only thing that
    /// distinguishes one tile from another, and a grid where every element announces
    /// "Image" is not navigable — then kind and state. The filename is derived from
    /// `MediaTileDetail.relativePath`, which the tile already holds, so this adds no
    /// query and does not widen `MediaTileDetail` (ENR-005).
    static func accessibilityLabel(
        detail: MediaTileDetail,
        badgeContent: TileBadgeContent
    ) -> String {
        let name = (detail.relativePath.rawValue as NSString).lastPathComponent
        let base: String = if detail.thumbnailUnavailable {
            detail.bestKind == .video
                ? "\(name), video, preview unavailable"
                : "\(name), image, preview unavailable"
        } else {
            switch badgeContent {
            case let .durationText(text): "\(name), video, \(text)"
            case .filmIcon: "\(name), video"
            case .rawLabel: "\(name), RAW image"
            case .none:
                switch detail.bestKind {
                case .video: "\(name), video"
                case .raw: "\(name), RAW image"
                case .image: "\(name), image"
                case .none: name
                }
            }
        }
        let emptySuffix = detail.enrichedSourceSize == 0 ? ", empty file" : ""
        return "\(base)\(emptySuffix), \(detail.mediaChoice.accessibilityValue)"
    }

    static func accessibilityValue(detail: MediaTileDetail) -> String {
        detail.mediaChoice.accessibilityValue
    }

    /// SF Symbol for the centered placeholder glyph. Loading uses kind glyphs
    /// (`r.square` for RAW); broken uses slash "unavailable" grammar. No spinner.
    static func placeholderIconSystemName(
        for kind: MediaKind?,
        thumbnailUnavailable: Bool
    ) -> String {
        if thumbnailUnavailable {
            return kind == .video ? "video.slash" : "photo.slash"
        }
        switch kind {
        case .video:
            return "film"
        case .raw:
            return "r.square"
        case .image, .none:
            return "photo"
        }
    }

    /// Cached SF Symbol image for placeholder tiles. `NSImage(systemSymbolName:)` creates
    /// a new image per call; resolve once per name and reuse. Main-actor confined —
    /// tiles are `@MainActor` AppKit views.
    @MainActor
    static func placeholderIcon(
        for kind: MediaKind?,
        thumbnailUnavailable: Bool = false
    ) -> NSImage? {
        let name = placeholderIconSystemName(for: kind, thumbnailUnavailable: thumbnailUnavailable)
        if let cached = placeholderIconCache[name] {
            return cached
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        placeholderIconCache[name] = image
        return image
    }

    @MainActor
    private static var placeholderIconCache: [String: NSImage?] = [:]

    static func contentRect(imagePixelSize: CGSize?, bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        guard let imagePixelSize,
              imagePixelSize.width > 0,
              imagePixelSize.height > 0
        else {
            return bounds.integral
        }
        let scale = min(bounds.width / imagePixelSize.width, bounds.height / imagePixelSize.height)
        let fittedWidth = min(bounds.width, max(1, (imagePixelSize.width * scale).rounded()))
        let fittedHeight = min(bounds.height, max(1, (imagePixelSize.height * scale).rounded()))
        return CGRect(
            x: bounds.minX + ((bounds.width - fittedWidth) / 2).rounded(),
            y: bounds.minY + ((bounds.height - fittedHeight) / 2).rounded(),
            width: fittedWidth,
            height: fittedHeight
        )
    }

    /// The aspect-fit thumbnail face inside `bounds`, used for both rendering and mouse
    /// hit-testing. For a not-yet-decoded placeholder (`imagePixelSize == nil`) the face is
    /// the full bounds, so the whole tile remains selectable.
    static func thumbnailFaceRect(imagePixelSize: CGSize?, bounds: CGRect) -> CGRect {
        contentRect(imagePixelSize: imagePixelSize, bounds: bounds)
    }

    /// Size gate for any lower-right badge content (duration, film icon, RAW).
    static func showsKindBadge(contentRect: CGRect) -> Bool {
        contentRect.width >= 56 && contentRect.height >= 56
    }

    /// Thumbnail path plus source stamp; badge updates do not change image identity.
    static func imageContentKey(_ detail: MediaTileDetail) -> String {
        let thumbnail = detail.thumbnailPath ?? ""
        let size = detail.enrichedSourceSize ?? -1
        let stamp = detail.enrichedSourceMTimeSeconds ?? -1
        return "\(thumbnail)#\(size)#\(stamp)"
    }

    static func decodedThumbnailImage(detail: MediaTileDetail, thumbnailDirectory: URL?) -> CGImage? {
        loadImage(detail: detail, thumbnailDirectory: thumbnailDirectory).image
    }

    static func loadImage(detail: MediaTileDetail, thumbnailDirectory: URL?) -> LoadedTile {
        let image = detail.thumbnailPath.flatMap { name in
            thumbnailDirectory.flatMap { ThumbnailStore.load(name, in: $0) }
        }
        return LoadedTile(
            image: image,
            pixelSize: image.map { CGSize(width: CGFloat($0.width), height: CGFloat($0.height)) }
        )
    }
}
