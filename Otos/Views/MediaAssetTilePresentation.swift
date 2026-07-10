import AppKit
import CoreGraphics
import Foundation

// Pure tile presentation guide
//
// These helpers keep kind-badge policy, thumbnail face geometry, and
// thumbnail-load policy independent from reusable AppKit view state. The AppKit
// tile calls into this file, and tests assert these value-level decisions directly.
// Lower-right badges appear only after a thumbnail has painted: video duration
// (or a film icon when duration is missing), or a RAW label for raw images.
// Placeholder tiles never show a lower-right badge — the centered kind glyph
// already communicates kind.

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

enum MediaAssetTilePresentation {
    static func isVideo(_ detail: MediaTileDetail) -> Bool {
        detail.bestKind == .video
    }

    /// Formats known finite video duration for the lower-right badge.
    nonisolated static func videoBadgeText(_ detail: MediaTileDetail) -> String? {
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

    /// Lower-right badge policy. Placeholder tiles never get a badge; painted
    /// video shows duration or a film-icon fallback; painted raw shows `RAW`.
    nonisolated static func badgeContent(
        detail: MediaTileDetail,
        thumbnailPainted: Bool
    ) -> TileBadgeContent {
        guard thumbnailPainted else {
            return .none
        }
        switch detail.bestKind {
        case .video:
            if let text = videoBadgeText(detail) {
                return .durationText(text)
            }
            return .filmIcon
        case .raw:
            return .rawLabel
        case .image, .none:
            return .none
        }
    }

    /// Accessibility label for the tile given badge content.
    nonisolated static func accessibilityLabel(for content: TileBadgeContent) -> String? {
        switch content {
        case let .durationText(text):
            "Video, \(text)"
        case .filmIcon:
            "Video"
        case .rawLabel:
            "RAW image"
        case .none:
            nil
        }
    }

    /// SF Symbol name for the placeholder icon: a film reel for a known video, a
    /// photo otherwise — covers both a known image and a not-yet-known kind.
    /// No spinner: a spinner on a merely queued tile would fabricate progress.
    nonisolated static func placeholderIconSystemName(for kind: MediaKind?) -> String {
        kind == .video ? "film" : "photo"
    }

    /// Cached SF Symbol image for placeholder tiles. `NSImage(systemSymbolName:)` creates
    /// a new image per call; there are only two icons (photo, film), so resolve once and
    /// reuse. Main-actor confined — tiles are `@MainActor` AppKit views.
    @MainActor
    static func placeholderIcon(for kind: MediaKind?) -> NSImage? {
        let name = placeholderIconSystemName(for: kind)
        if let cached = placeholderIconCache[name] {
            return cached
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        placeholderIconCache[name] = image
        return image
    }

    @MainActor
    private static var placeholderIconCache: [String: NSImage?] = [:]

    nonisolated static func contentRect(imagePixelSize: CGSize?, bounds: CGRect) -> CGRect {
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
    nonisolated static func thumbnailFaceRect(imagePixelSize: CGSize?, bounds: CGRect) -> CGRect {
        contentRect(imagePixelSize: imagePixelSize, bounds: bounds)
    }

    /// Size gate for any lower-right badge content (duration, film icon, RAW).
    nonisolated static func showsKindBadge(contentRect: CGRect) -> Bool {
        contentRect.width >= 56 && contentRect.height >= 56
    }

    /// Thumbnail path plus source stamp; badge updates do not change image identity.
    nonisolated static func imageContentKey(_ detail: MediaTileDetail) -> String {
        let thumbnail = detail.thumbnailPath ?? ""
        let size = detail.enrichedSourceSize ?? -1
        let stamp = detail.enrichedSourceMTimeSeconds ?? -1
        return "\(thumbnail)#\(size)#\(stamp)"
    }

    nonisolated static func decodedThumbnailImage(detail: MediaTileDetail, thumbnailDirectory: URL?) -> CGImage? {
        loadImage(detail: detail, thumbnailDirectory: thumbnailDirectory).image
    }

    nonisolated static func loadImage(detail: MediaTileDetail, thumbnailDirectory: URL?) -> LoadedTile {
        let image = detail.thumbnailPath.flatMap { name in
            thumbnailDirectory.flatMap { ThumbnailStore.load(name, in: $0) }
        }
        return LoadedTile(
            image: image,
            pixelSize: image.map { CGSize(width: CGFloat($0.width), height: CGFloat($0.height)) }
        )
    }
}
