import CoreGraphics
import Foundation

// Pure tile presentation guide
//
// These helpers keep video badge policy, thumbnail face geometry, and
// thumbnail-load policy independent from reusable AppKit view state. The AppKit
// tile calls into this file, and tests assert these value-level decisions directly.

struct LoadedTile {
    let image: CGImage?
    let pixelSize: CGSize?
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

    static func videoBadgeFrame(
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

    static func videoBadgeWidth(durationTextWidth: CGFloat?) -> CGFloat {
        guard let durationTextWidth else {
            return badgeMinWidth
        }
        return max(
            badgeMinWidth,
            ceil(durationTextWidth) + badgeHorizontalPadding * 2
        )
    }

    static func videoBadgeDurationFrame(badgeWidth: CGFloat) -> CGRect {
        CGRect(
            x: badgeHorizontalPadding,
            y: badgeTextY,
            width: max(badgeWidth - badgeHorizontalPadding * 2, 0),
            height: badgeTextHeight
        )
    }
}

nonisolated struct TilePaintContext {
    let incomingKey: String
    let incomingThumbnailPath: String?
    let currentKey: String?
    let currentAssetID: MediaAssetID?
    let incomingAssetID: MediaAssetID
    let cacheHasImage: Bool
    let hasPaintedImage: Bool
}

nonisolated enum TilePaintDecision: Equatable {
    case paintCached
    case keepCurrent
    case loadAsync(retainsCurrentImage: Bool)
    case placeholder
}

enum MediaAssetTilePresentation {
    static func isVideo(_ detail: MediaTileDetail) -> Bool {
        detail.bestKind == .video
    }

    nonisolated static func videoBadgeText(_ detail: MediaTileDetail) -> String? {
        guard showsVideoBadge(detail),
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

    nonisolated static func showsVideoBadge(_ detail: MediaTileDetail) -> Bool {
        detail.bestKind == .video
    }

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

    nonisolated static func showsVideoBadge(contentRect: CGRect) -> Bool {
        contentRect.width >= 56 && contentRect.height >= 56
    }

    nonisolated static func paintDecision(_ context: TilePaintContext) -> TilePaintDecision {
        if context.cacheHasImage {
            return .paintCached
        }
        if context.incomingKey == context.currentKey {
            return .keepCurrent
        }
        let sameIdentity = context.currentAssetID == context.incomingAssetID
        if context.incomingThumbnailPath == nil {
            return sameIdentity && context.hasPaintedImage ? .keepCurrent : .placeholder
        }
        return .loadAsync(retainsCurrentImage: sameIdentity && context.hasPaintedImage)
    }

    /// Thumbnail path plus source stamp; video-badge updates do not change image identity.
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
